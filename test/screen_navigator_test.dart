import 'package:test/test.dart';

import 'package:dangi_doctor/crawler/screen_navigator.dart';

void main() {
  group('screenNameTier', () {
    test('Page/Screen names rank highest', () {
      expect(screenNameTier('HomePage'), kScreenTierPageScreen);
      expect(screenNameTier('SettingsScreen'), kScreenTierPageScreen);
      // FlutterFlow: ends in Widget but contains "page"
      expect(screenNameTier('HomePageWidget'), kScreenTierPageScreen);
    });

    test('plain *Widget leaves rank below screens', () {
      expect(screenNameTier('AvatarWidget'), kScreenTierWidget);
      expect(screenNameTier('IconWidget'), kScreenTierWidget);
    });

    test('splash/init rank lowest — deprioritized even if named *Screen', () {
      expect(screenNameTier('SplashScreen'), kScreenTierSplash);
      expect(screenNameTier('AppInitializer'), kScreenTierSplash);
    });

    test('non-screen names are skipped', () {
      expect(screenNameTier('Scaffold'), kScreenTierSkip);
      expect(screenNameTier('Column'), kScreenTierSkip);
    });
  });

  group('detectScreenNameFromTree', () {
    Map<String, dynamic> node(String type,
            [List<Map<String, dynamic>> kids = const []]) =>
        {'widgetRuntimeType': type, 'children': kids};

    test('picks the page over a nested leaf *Widget (the AvatarWidget decoy)',
        () {
      final tree = node('MaterialApp', [
        node('HomePage', [
          node('Column', [node('AvatarWidget')]),
        ]),
      ]);
      expect(detectScreenNameFromTree(tree), 'HomePage');
    });

    test('picks the DEEPEST page — the top of a pushed navigation stack', () {
      // Navigator holding [HomePage, SettingsPage] after context.push.
      final tree = node('MaterialApp', [
        node('Navigator', [
          node('HomePage', [node('AvatarWidget')]),
          node('SettingsPage', [node('Column')]),
        ]),
      ]);
      expect(detectScreenNameFromTree(tree), 'SettingsPage');
    });

    test('ignores navbar containers', () {
      final tree = node('MaterialApp', [
        node('ProfilePage'),
        node('BottomNavBarWidget'),
      ]);
      expect(detectScreenNameFromTree(tree), 'ProfilePage');
    });

    test('deprioritizes splash when a real screen is present', () {
      final tree = node('MaterialApp', [
        node('SplashScreen'),
        node('DashboardPage'),
      ]);
      expect(detectScreenNameFromTree(tree), 'DashboardPage');
    });

    test('returns UnknownScreen for an obfuscated tree', () {
      final tree = node('MaterialApp', [node('Column'), node('Padding')]);
      expect(detectScreenNameFromTree(tree), 'UnknownScreen');
    });
  });

  group('isLeaveDialogLabel', () {
    test('matches real leave/confirm buttons by whole word', () {
      expect(isLeaveDialogLabel('Leave'), isTrue);
      expect(isLeaveDialogLabel('OK'), isTrue);
      expect(isLeaveDialogLabel('Yes, discard'), isTrue);
      expect(isLeaveDialogLabel('Go Back'), isTrue);
    });

    test('does NOT tap substring traps', () {
      expect(isLeaveDialogLabel('Booking'), isFalse); // contains "ok"
      expect(isLeaveDialogLabel('Eyes Only'), isFalse); // contains "yes"
      expect(isLeaveDialogLabel('Bookmark'), isFalse);
      expect(isLeaveDialogLabel('Cookies'), isFalse);
    });

    test('stay keywords win over leave keywords', () {
      expect(isLeaveDialogLabel('No, keep it'), isFalse);
      expect(isLeaveDialogLabel('Cancel'), isFalse);
    });
  });

  group('parseUiautomatorTappables', () {
    // Builds one attribute-complete uiautomator node, matching real dumps.
    String uiNode({
      String text = '',
      String contentDesc = '',
      bool clickable = true,
      required String bounds,
    }) =>
        '<node index="0" text="$text" resource-id="" '
        'class="android.view.View" package="com.example.app" '
        'content-desc="$contentDesc" checkable="false" checked="false" '
        'clickable="$clickable" enabled="true" focusable="true" '
        'focused="false" scrollable="false" long-clickable="false" '
        'password="false" selected="false" bounds="$bounds" />';

    String uiDump(List<String> nodes) =>
        "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>"
        '<hierarchy rotation="0">'
        '<node index="0" text="" resource-id="" '
        'class="android.widget.FrameLayout" package="com.example.app" '
        'content-desc="" checkable="false" checked="false" clickable="false" '
        'enabled="true" focusable="false" focused="false" scrollable="false" '
        'long-clickable="false" password="false" selected="false" '
        'bounds="[0,0][1080,2400]">${nodes.join()}</node></hierarchy>';

    test('extracts clickable elements with centres, sorted top-to-bottom', () {
      final xml = uiDump([
        uiNode(contentDesc: 'Profile', bounds: '[0,1000][1080,1100]'),
        uiNode(text: 'Settings', bounds: '[0,200][1080,300]'),
        uiNode(
            text: 'Not clickable',
            clickable: false,
            bounds: '[0,400][1080,500]'),
      ]);
      final result = parseUiautomatorTappables(xml);
      expect(result, hasLength(2));
      expect(result[0], (cx: 540, cy: 250, desc: 'Settings'));
      expect(result[1], (cx: 540, cy: 1050, desc: 'Profile'));
    });

    test('prefers content-desc over text, falls back to tap(cx,cy)', () {
      final xml = uiDump([
        uiNode(
            contentDesc: 'Open menu', text: 'Menu', bounds: '[0,100][100,200]'),
        uiNode(bounds: '[0,300][100,400]'),
      ]);
      final result = parseUiautomatorTappables(xml);
      expect(result[0].desc, 'Open menu');
      expect(result[1].desc, 'tap(50,350)');
    });

    test('drops tiny (<20px) elements and duplicate centres', () {
      final xml = uiDump([
        uiNode(text: 'Tiny', bounds: '[0,100][15,300]'),
        uiNode(text: 'First', bounds: '[0,500][100,600]'),
        uiNode(text: 'SameCentre', bounds: '[10,510][90,590]'),
      ]);
      final result = parseUiautomatorTappables(xml);
      expect(result, hasLength(1));
      expect(result.single.desc, 'First');
    });

    test('decodes XML entities so labels match what the user sees', () {
      final xml = uiDump([
        uiNode(
            contentDesc: 'Terms &amp; Conditions', bounds: '[0,100][1080,200]'),
        uiNode(text: 'Say &quot;Yes&quot;', bounds: '[0,300][1080,400]'),
        uiNode(
            contentDesc: '&lt;New&gt; &apos;Item&apos;',
            bounds: '[0,500][1080,600]'),
        uiNode(contentDesc: 'Literal &amp;lt;', bounds: '[0,700][1080,800]'),
      ]);
      final descs = parseUiautomatorTappables(xml).map((e) => e.desc).toList();
      expect(descs, [
        'Terms & Conditions',
        'Say "Yes"',
        "<New> 'Item'",
        'Literal &lt;', // &amp; decoded LAST — no double decode
      ]);
    });

    test('decoded &#10; newlines drive list-item deduplication', () {
      final xml = uiDump([
        uiNode(
            contentDesc: 'Order #1&#10;Delivered yesterday',
            bounds: '[40,400][1040,560]'),
        uiNode(
            contentDesc: 'Order #2&#10;Delivered last week',
            bounds: '[40,580][1040,740]'),
        uiNode(
            contentDesc: 'Order #3&#10;Delivered last month',
            bounds: '[40,760][1040,920]'),
        uiNode(contentDesc: 'Open basket', bounds: '[880,2200][1040,2320]'),
      ]);
      final descs = parseUiautomatorTappables(xml).map((e) => e.desc).toList();
      expect(descs, [
        'Order #1\nDelivered yesterday', // first row kept, entity decoded
        'Open basket', // different column — not a list row
      ]);
    });

    test('returns empty for empty or non-XML input', () {
      expect(parseUiautomatorTappables(''), isEmpty);
      expect(parseUiautomatorTappables('error: device offline'), isEmpty);
    });
  });
}
