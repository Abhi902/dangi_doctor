import 'dart:async';
import 'package:vm_service/vm_service.dart';

/// Navigates the running Flutter app to named routes by evaluating Dart
/// expressions directly inside the app's isolate via the VM service.
///
/// **Why scope-injection?**
/// The Dart VM evaluate() API, when given a *library* as target, only resolves
/// names that are *imported* by that library — it does NOT see the library's
/// own top-level declarations. So `navigatorKey` (defined in nav.dart) cannot
/// be referenced when evaluating IN nav.dart's library context.
///
/// Fix: locate the live GlobalKey<NavigatorState> instance on the heap via
/// getInstances(), then inject it as a named variable in evaluate()'s `scope`
/// parameter. Extension methods (go/goNamed from go_router) are resolved
/// against nav.dart's library context, where they are in scope via the
/// circular import chain: nav.dart → flutter_flow_util.dart → nav.dart export
/// → go_router export.
class VmEvaluator {
  final VmService vmService;
  final String isolateId;
  final String routerType;
  final String? routerVariable;

  /// Library ID of nav.dart (or equivalent) — used as evaluate context.
  String? _bestLibId;

  /// Object ID of the live navigatorKey GlobalKey<NavigatorState> instance.
  String? _navKeyObjectId;

  /// All user-package library IDs (fallback pool for GetX / other strategies).
  final List<String> _allLibIds = [];

  VmEvaluator({
    required this.vmService,
    required this.isolateId,
    this.routerType = 'unknown',
    this.routerVariable,
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Initialisation
  // ───────────────────────────────────────────────────────────────────────────

  /// Finds:
  ///  1. The library that DEFINES navigatorKey (via getObject variable scan).
  ///  2. The live GlobalKey<NavigatorState> heap instance (via getInstances).
  ///
  /// Must be called before [navigateTo].
  Future<void> init() async {
    try {
      final isolate = await vmService.getIsolate(isolateId);
      final libs = isolate.libraries ?? [];

      // Build a sorted library pool for fallback strategies.
      final sorted = [
        ...libs.where((l) {
          final u = l.uri ?? '';
          return u.contains('/pages/') ||
              u.contains('_widget') ||
              u.endsWith('/nav.dart');
        }),
        ...libs.where((l) => (l.uri ?? '').endsWith('main.dart')),
        ...libs.where((l) {
          final u = l.uri ?? '';
          return u.startsWith('package:') &&
              !u.contains('/pages/') &&
              !u.contains('_widget') &&
              !u.endsWith('/nav.dart') &&
              !u.endsWith('main.dart');
        }),
      ];
      for (final lib in sorted) {
        if (lib.id != null) _allLibIds.add(lib.id!);
      }

      // Step 1 — find nav.dart (library that DEFINES navigatorKey).
      print('  🔎 Scanning ${libs.length} libraries for navigation key...');
      for (final libRef in libs) {
        if (libRef.id == null) continue;
        final uri = libRef.uri ?? '';
        if (!uri.startsWith('package:') && !uri.startsWith('file:')) {
          continue;
        }
        if (uri.startsWith('package:flutter') ||
            uri.startsWith('package:dart') ||
            uri.startsWith('dart:')) {
          continue;
        }

        try {
          final obj = await vmService
              .getObject(isolateId, libRef.id!)
              .timeout(const Duration(milliseconds: 500));
          if (obj is Library) {
            final hasNavKey =
                obj.variables?.any((v) => v.name == 'navigatorKey') ?? false;
            if (hasNavKey) {
              _bestLibId = libRef.id!;
              print('  ✅ navigatorKey defined in: $uri');
              break;
            }
          }
        } catch (_) {
          continue;
        }
      }

      if (_bestLibId == null) {
        print('  ⚠️  navigatorKey definition not found — trying fallbacks');
      }

      // Step 1b — probe compiler availability with a trivial library-context
      // expression. Instance-level evaluate() (used in Step 2) works without
      // the Dart frontend compiler, so we must test library-level here to
      // detect a stale / orphaned VM service before Phase 1 begins.
      if (_bestLibId != null) {
        try {
          await vmService
              .evaluate(isolateId, _bestLibId!, '1 + 1')
              .timeout(const Duration(seconds: 3));
        } on RPCError catch (e) {
          final detail = e.data?.toString() ?? '';
          if (detail.contains('No compilation service')) {
            _evaluateAvailable = false;
            print(
                '  ⚠️  VM evaluate unavailable: no Dart compilation service.');
            print('       Phase 1 will be skipped.');
          }
        } catch (_) {
          // Other errors (timeout, etc.) don't indicate missing compiler.
        }
      }

      // Step 2 — find the live GlobalKey<NavigatorState> heap instance.
      await _findNavigatorKeyInstance(libs);
    } catch (e) {
      print('  ⚠️  VmEvaluator init failed: $e');
    }
  }

  /// Locates the GlobalKey<NavigatorState> object in the isolate heap.
  ///
  /// Strategy:
  ///   a. Scan flutter widget framework library for the GlobalKey class.
  ///   b. Call getInstances() to list all GlobalKey instances.
  ///   c. For each instance, evaluate `currentState != null` on it —
  ///      the one that returns true is the navigator key.
  Future<void> _findNavigatorKeyInstance(List<LibraryRef> libs) async {
    try {
      // (a) Find GlobalKey class ID in flutter widgets library.
      String? globalKeyClassId;
      for (final libRef in libs) {
        final uri = libRef.uri ?? '';
        if (!uri.contains('flutter') ||
            (!uri.contains('widgets/framework') &&
                !uri.contains('flutter/src/widgets'))) {
          continue;
        }
        if (libRef.id == null) continue;

        try {
          final obj = await vmService
              .getObject(isolateId, libRef.id!)
              .timeout(const Duration(milliseconds: 500));
          if (obj is Library) {
            final keyClass =
                obj.classes?.where((c) => c.name == 'GlobalKey').firstOrNull;
            if (keyClass?.id != null) {
              globalKeyClassId = keyClass!.id;
              break;
            }
          }
        } catch (_) {
          continue;
        }
      }

      if (globalKeyClassId == null) {
        print(
            '  ⚠️  GlobalKey class not found in heap — scope injection unavailable');
        return;
      }

      // (b) List all GlobalKey instances.
      final instances = await vmService
          .getInstances(isolateId, globalKeyClassId, 200)
          .timeout(const Duration(seconds: 5));

      // (c) Find the one that has a NavigatorState attached.
      for (final inst in instances.instances ?? []) {
        if (inst.id == null) continue;
        try {
          final result = await vmService
              .evaluate(isolateId, inst.id!, 'currentState != null')
              .timeout(const Duration(milliseconds: 800));
          if (result is InstanceRef && result.valueAsString == 'true') {
            _navKeyObjectId = inst.id;
            print('  ✅ navigatorKey instance found in heap');
            break;
          }
        } on RPCError catch (e) {
          final detail = e.data?.toString() ?? '';
          if (detail.contains('No compilation service')) {
            _evaluateAvailable = false;
            print(
                '  ⚠️  VM evaluate unavailable: no Dart compilation service attached.');
            print(
                '       Phase 1 will be skipped. Delete .dangi_doctor/vm_url.txt and rerun for a fresh connection.');
            return;
          }
          continue;
        } catch (_) {
          continue;
        }
      }

      if (_navKeyObjectId == null) {
        print('  ⚠️  No GlobalKey<NavigatorState> with active state found');
      }
    } catch (e) {
      print('  ⚠️  navigatorKey instance search failed: $e');
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Navigation
  // ───────────────────────────────────────────────────────────────────────────

  bool _firstNav = true;

  /// False when the Dart frontend compiler is not attached (e.g. connecting to
  /// an orphaned VM service after the original `flutter run` process has exited).
  /// All evaluate() calls will fail with "No compilation service available" in
  /// that case, so we detect it once and skip Phase 1 entirely.
  bool _evaluateAvailable = true;

  bool get canEvaluate => _evaluateAvailable;

  /// Attempt to navigate to [route].
  ///
  /// Returns true if at least one evaluate call triggered navigation.
  Future<bool> navigateTo(String route) async {
    if (!_evaluateAvailable) return false;
    final absPath = route.startsWith('/') ? route : '/$route';
    final v = _firstNav;
    _firstNav = false;

    // ── Strategy 1: scope-injected navigatorKey (primary approach) ──────────
    //
    // We inject the live GlobalKey instance as `_nk` and evaluate go_router
    // extension methods in nav.dart's library context (where they are in scope
    // via the circular import → export chain).
    if (_navKeyObjectId != null && _bestLibId != null) {
      final scope = {'_nk': _navKeyObjectId!};

      if (await _eval("_nk.currentContext?.goNamed('$route')", _bestLibId!,
          verbose: v, scope: scope)) {
        return true;
      }

      if (await _eval("_nk.currentContext?.go('$absPath')", _bestLibId!,
          verbose: v, scope: scope)) {
        return true;
      }

      // FlutterFlow's auth-bypassing helper
      if (await _eval(
          "_nk.currentContext?.goNamedAuth('$route', true)", _bestLibId!,
          verbose: v, scope: scope)) {
        return true;
      }
    }

    // ── Strategy 2: evaluate directly on navigatorKey instance ──────────────
    //
    // `currentState?.pushNamed` is from flutter/material — always in scope
    // when evaluating on the NavigatorKey instance.
    if (_navKeyObjectId != null) {
      if (await _eval("currentState?.pushNamed('$absPath')", _navKeyObjectId!,
          verbose: v)) {
        return true;
      }
    }

    // ── Strategy 3: GetX ────────────────────────────────────────────────────
    for (final libId in _allLibIds.take(5)) {
      if (await _eval("Get.toNamed('$absPath')", libId)) return true;
    }

    // ── Strategy 4: GoRouter top-level vars ─────────────────────────────────
    final vars = <String>{
      if (routerVariable != null) routerVariable!,
      'router',
      '_router',
      'appRouter',
      'goRouter',
    };
    for (final varName in vars) {
      for (final libId in _allLibIds.take(3)) {
        if (await _eval("$varName.goNamed('$route')", libId)) return true;
        if (await _eval("$varName.go('$absPath')", libId)) return true;
      }
    }

    // ── Strategy 5: Navigator 1.0 via best lib (no scope injection) ─────────
    if (_bestLibId != null) {
      if (await _eval(
          "navigatorKey.currentState?.pushNamed('$absPath')", _bestLibId!,
          verbose: v)) {
        return true;
      }
    }

    return false;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Evaluate helper
  // ───────────────────────────────────────────────────────────────────────────

  Future<bool> _eval(
    String expression,
    String targetId, {
    bool verbose = false,
    Map<String, String>? scope,
  }) async {
    try {
      final result = await vmService
          .evaluate(isolateId, targetId, expression, scope: scope)
          .timeout(const Duration(milliseconds: 2000));
      if (verbose) {
        print('  ✅ eval OK: $expression → ${result.runtimeType}');
      }
      return true;
    } on RPCError catch (e) {
      final detail = e.data?.toString() ?? '';
      if (detail.contains('No compilation service')) {
        if (_evaluateAvailable) {
          _evaluateAvailable = false;
          print(
              '  ⚠️  VM evaluate disabled: no Dart compilation service attached.');
          print(
              '       Phase 1 skipped. Delete .dangi_doctor/vm_url.txt and rerun to get a fresh connection.');
        }
      } else if (verbose) {
        print('  ❌ RPCError (${e.code}): ${e.message} | expr: $expression');
        if (e.data != null) print('     detail: ${e.data}');
      }
      return false;
    } on TimeoutException {
      if (verbose) print('  ⏱️  Timeout: $expression');
      return false;
    } catch (e) {
      if (verbose) {
        print('  ❌ ${e.runtimeType}: $e | expr: $expression');
      }
      return false;
    }
  }
}
