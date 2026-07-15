import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

// Crawler playground — a deliberately adversarial Flutter app that exercises
// each behavior the dangi_doctor crawler needs to get right. Each screen is
// annotated with the GROUND TRUTH the crawler should produce.

final _router = GoRouter(
  navigatorKey: GlobalKey<NavigatorState>(),
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', name: 'home', builder: (c, s) => const HomePage()),
    GoRoute(
        path: '/settings',
        name: 'settings',
        builder: (c, s) => const SettingsPage()),
    GoRoute(
        path: '/profile',
        name: 'profile',
        builder: (c, s) => const ProfilePage()),
    GoRoute(path: '/list', name: 'list', builder: (c, s) => const ListPage()),
    GoRoute(
        path: '/detail/:id',
        name: 'detail',
        builder: (c, s) => DetailPage(id: s.pathParameters['id']!)),
    GoRoute(
        path: '/traps', name: 'traps', builder: (c, s) => const TrapsPage()),
    // A dangerous route Phase 1 must NOT auto-navigate.
    GoRoute(
        path: '/logout', name: 'logout', builder: (c, s) => const LogoutPage()),
  ],
);

void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(routerConfig: _router);
  }
}

/// GROUND TRUTH: screen name = "HomePage". Contains a nested leaf widget
/// `AvatarWidget` (ends in "Widget") — the crawler must NOT report that as
/// the screen name (the "deepest Widget wins" bug).
class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AvatarWidget(), // decoy: ends in "Widget", is NOT the screen
            _NavButton('Open Settings', '/settings'),
            _NavButton('Open Profile', '/profile'),
            _NavButton('Open List', '/list'),
            _NavButton('Open Traps', '/traps'),
          ],
        ),
      ),
    );
  }
}

/// A leaf custom widget that ends in "Widget" — decoy for screen-name detection.
class AvatarWidget extends StatelessWidget {
  const AvatarWidget({super.key});
  @override
  Widget build(BuildContext context) =>
      const CircleAvatar(radius: 24, child: Icon(Icons.person));
}

/// GROUND TRUTH: screen name = "SettingsPage".
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [_NavButton('Go to Profile', '/profile')],
        ),
      ),
    );
  }
}

/// GROUND TRUTH: screen name = "ProfilePage".
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: const Center(child: Text('Profile content')),
    );
  }
}

/// GROUND TRUTH: screen name = "ListPage". Tapping any row PUSHES a detail
/// page (stack push, not replace) so BACK returns here — verifies the crawler
/// returns correctly instead of exiting the app.
class ListPage extends StatelessWidget {
  const ListPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('List')),
      body: ListView(
        children: [
          for (var i = 1; i <= 4; i++)
            ListTile(
              key: Key('row_$i'),
              title: Text('Item number $i\nsubtitle line for item $i'),
              onTap: () => context.push('/detail/$i'),
            ),
        ],
      ),
    );
  }
}

/// GROUND TRUTH: screen name = "DetailPage".
class DetailPage extends StatelessWidget {
  final String id;
  const DetailPage({super.key, required this.id});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Detail $id')),
      body: Center(child: Text('Detail for item $id')),
    );
  }
}

/// GROUND TRUTH: screen name = "TrapsPage". The two buttons are substring
/// traps: "Booking" contains "ok" and "Eyes Only" contains "yes". A crawler
/// using substring matching for dialog dismissal would wrongly treat these as
/// leave/confirm buttons. There is NO dialog here — tapping them must be
/// treated as ordinary navigation (they go nowhere), and the dialog-dismissal
/// logic must never fire on this screen.
class TrapsPage extends StatelessWidget {
  const TrapsPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Traps')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton(
              onPressed: () {},
              child: const Text('Booking'), // contains "ok"
            ),
            ElevatedButton(
              onPressed: () {},
              child: const Text('Eyes Only'), // contains "yes"
            ),
          ],
        ),
      ),
    );
  }
}

/// GROUND TRUTH: reachable only by explicit user intent. Phase 1 route
/// injection must SKIP /logout (dangerous-label gate).
class LogoutPage extends StatelessWidget {
  const LogoutPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Logged out')),
      body: const Center(child: Text('You have been logged out')),
    );
  }
}

class _NavButton extends StatelessWidget {
  final String label;
  final String route;
  const _NavButton(this.label, this.route);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: ElevatedButton(
        onPressed: () => context.push(route),
        child: Text(label),
      ),
    );
  }
}
