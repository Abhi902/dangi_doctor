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
}
