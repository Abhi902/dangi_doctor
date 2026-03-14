class WidgetIssue {
  final String type;
  final String message;
  final String severity; // 'error', 'warning', 'info'
  final String? file;
  final int? line;

  WidgetIssue({
    required this.type,
    required this.message,
    required this.severity,
    this.file,
    this.line,
  });

  @override
  String toString() {
    final location = file != null ? ' (${file!.split('/').last}:$line)' : '';
    final icon = severity == 'error'
        ? '🔴'
        : severity == 'warning'
            ? '🟡'
            : '🔵';
    return '$icon [$type]$location $message';
  }
}

class TreeAnalyser {
  final List<WidgetIssue> issues = [];
  int maxDepthFound = 0;
  int totalWidgets = 0;
  Map<String, int> widgetCounts = {};
  void analyse(Map<String, dynamic> tree) {
    issues.clear();
    maxDepthFound = 0;
    totalWidgets = 0;
    widgetCounts = {};
    _walkTree(tree, depth: 0);
    _checkProviderNesting(tree);
  }

  void _walkTree(dynamic node, {required int depth}) {
    if (node == null) return;

    totalWidgets++;

    final widgetType = node['widgetRuntimeType'] as String? ??
        node['description'] as String? ??
        'Unknown';
    widgetCounts[widgetType] = (widgetCounts[widgetType] ?? 0) + 1;

    final file = node['creationLocation']?['file'] as String?;
    final line = node['creationLocation']?['line'] as int?;
    final shortFile = file?.split('/').last;

    if (depth > maxDepthFound) maxDepthFound = depth;

    // Skip provider/infrastructure widgets for nesting check
    final isInfraWidget = widgetType.contains('Provider') ||
        widgetType.contains('Consumer') ||
        widgetType == 'MultiProvider' ||
        widgetType == 'Builder' ||
        widgetType == 'ScreenUtilInit' ||
        widgetType == 'StreamBuilder' ||
        widgetType == 'MyApp' ||
        widgetType == 'MyStartupTimerWrapper' ||
        widgetType == 'RootWidget' ||
        widgetType == 'MaterialApp' ||
        widgetType == '_NestedHook' ||
        widgetType == 'InheritedGoRouter' ||
        widgetType == '_CustomNavigator' ||
        widgetType == 'GoRouterStateRegistryScope' ||
        widgetType == 'HeroControllerScope' ||
        widgetType == 'Navigator' ||
        widgetType == 'VectorGraphic' ||
        widgetType == '_RawPictureVectorGraphicWidget' ||
        widgetType.startsWith('_Inherited');

    // Check 1: deep nesting — UI widgets only
    if (depth > 15 && !isInfraWidget) {
      issues.add(WidgetIssue(
        type: 'DEEP_NESTING',
        message: '$widgetType nested ${depth}lvl deep — extract into a widget.',
        severity: depth > 25 ? 'error' : 'warning',
        file: shortFile,
        line: line,
      ));
    }

    // Check 2: stateful widget with no children
    if (node['stateful'] == true && node['hasChildren'] != true) {
      issues.add(WidgetIssue(
        type: 'UNNECESSARY_STATEFUL',
        message: '$widgetType is stateful but has no children.',
        severity: 'warning',
        file: shortFile,
        line: line,
      ));
    }

    // Check 3: excessive SizedBox
    if (widgetType == 'SizedBox') {
      if ((widgetCounts['SizedBox'] ?? 0) == 10) {
        issues.add(WidgetIssue(
          type: 'EXCESSIVE_SIZEDBOX',
          message: '10+ SizedBox widgets on screen. Use spacing in Column/Row.',
          severity: 'info',
          file: shortFile,
          line: line,
        ));
      }
    }

    // Check 4: redundant Align inside Align
    if (widgetType == 'Align') {
      final children = node['children'] as List? ?? [];
      for (final child in children) {
        if ((child['widgetRuntimeType'] ?? child['description']) == 'Align') {
          issues.add(WidgetIssue(
            type: 'REDUNDANT_ALIGN',
            message: 'Align inside Align — outer one is redundant.',
            severity: 'warning',
            file: shortFile,
            line: line,
          ));
        }
      }
    }

    // Check 5: Container with single child
    if (widgetType == 'Container') {
      final children = node['children'] as List? ?? [];
      if (children.length == 1) {
        issues.add(WidgetIssue(
          type: 'CONTAINER_VS_SIZEDBOX',
          message: 'Container with single child — prefer SizedBox or Padding.',
          severity: 'info',
          file: shortFile,
          line: line,
        ));
      }
    }

    // Recurse
    final children = node['children'] as List? ?? [];
    for (final child in children) {
      _walkTree(child, depth: depth + 1);
    }
  }

  void _checkProviderNesting(dynamic tree) {
    // Count provider depth at root level
    int providerCount = 0;
    dynamic current = tree;

    while (current != null) {
      final type = current['widgetRuntimeType'] as String? ?? '';
      if (type.contains('Provider') || type.contains('Consumer')) {
        providerCount++;
      }
      final children = current['children'] as List?;
      current =
          (children != null && children.isNotEmpty) ? children.first : null;
    }

    if (providerCount > 8) {
      issues.add(WidgetIssue(
        type: 'PROVIDER_OVERLOAD',
        message: 'Found $providerCount Provider/Consumer widgets in the tree. '
            'Consider consolidating with a single MultiProvider at the root.',
        severity: 'warning',
      ));
    }
  }

  void printSummary() {
    print('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    print('🩺 DANGI DOCTOR — DIAGNOSIS REPORT');
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    print('📊 Total widgets on screen : $totalWidgets');
    print('📏 Maximum nesting depth   : $maxDepthFound');
    print('🔍 Issues found            : ${issues.length}');
    print('');

    if (issues.isEmpty) {
      print('✅ No issues found. Your app looks healthy!');
      return;
    }

    final errors = issues.where((i) => i.severity == 'error').toList();
    final warnings = issues.where((i) => i.severity == 'warning').toList();
    final infos = issues.where((i) => i.severity == 'info').toList();

    if (errors.isNotEmpty) {
      print('🔴 ERRORS (${errors.length})');
      for (final i in errors) print('  $i');
      print('');
    }
    if (warnings.isNotEmpty) {
      print('🟡 WARNINGS (${warnings.length})');
      for (final i in warnings) print('  $i');
      print('');
    }
    if (infos.isNotEmpty) {
      print('🔵 INFO (${infos.length})');
      for (final i in infos) print('  $i');
      print('');
    }

    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

    // Top 5 most used widgets
    print('\n📦 Top widgets on this screen:');
    final sorted = widgetCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final entry in sorted.take(5)) {
      print('  ${entry.key}: ${entry.value}x');
    }
  }
}
