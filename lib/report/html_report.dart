import 'dart:io';
import '../crawler/screen_navigator.dart';
import '../generator/app_analyser.dart';

/// Generates a self-contained HTML health report for all discovered screens
/// and writes it to `.dangi_doctor/report_<timestamp>.html` in the project.
class HtmlReportGenerator {
  /// Generate an HTML health report and auto-open it in the browser.
  /// Returns the path to the saved file.
  static Future<String> generate({
    required List<DiscoveredScreen> screens,
    required List<KnownRisk> knownRisks,
    required String projectPath,
    required String projectName,
  }) async {
    final timestamp = DateTime.now();
    final ts = '${timestamp.year}'
        '${timestamp.month.toString().padLeft(2, '0')}'
        '${timestamp.day.toString().padLeft(2, '0')}_'
        '${timestamp.hour.toString().padLeft(2, '0')}'
        '${timestamp.minute.toString().padLeft(2, '0')}';

    final outDir = Directory('$projectPath/.dangi_doctor');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final outPath = '${outDir.path}/report_$ts.html';

    final html = _buildHtml(
      screens: screens,
      knownRisks: knownRisks,
      projectName: projectName,
      timestamp: timestamp,
    );

    File(outPath).writeAsStringSync(html);
    print('\n📊 Report saved: $outPath');

    // Auto-open
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [outPath]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [outPath]);
      } else if (Platform.isWindows) {
        await Process.run('start', [outPath], runInShell: true);
      }
    } catch (_) {}

    return outPath;
  }

  // ─────────────────────────────────────────────────────────────────────────

  static int _healthScore(
      List<DiscoveredScreen> screens, List<KnownRisk> knownRisks) {
    int score = 100;
    for (final s in screens) {
      for (final i in s.issues) {
        if (i.severity == 'error') score -= 5;
        if (i.severity == 'warning') score -= 2;
      }
      final grade = s.performance?.grade ?? 'N/A';
      if (grade == 'D' || grade == 'F') score -= 5;
    }
    score -= knownRisks.length * 8;
    return score.clamp(0, 100);
  }

  static String _gradeColor(String grade) => switch (grade) {
        'A' => '#22c55e',
        'B' => '#84cc16',
        'C' => '#f59e0b',
        'D' => '#f97316',
        _ => '#ef4444',
      };

  static String _severityColor(String sev) => switch (sev) {
        'error' => '#ef4444',
        'warning' => '#f59e0b',
        _ => '#3b82f6',
      };

  static String _scoreColor(int score) {
    if (score >= 80) return '#22c55e';
    if (score >= 60) return '#f59e0b';
    return '#ef4444';
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  // ─────────────────────────────────────────────────────────────────────────

  static String _buildHtml({
    required List<DiscoveredScreen> screens,
    required List<KnownRisk> knownRisks,
    required String projectName,
    required DateTime timestamp,
  }) {
    final score = _healthScore(screens, knownRisks);
    final scoreColor = _scoreColor(score);
    final totalIssues = screens.fold(0, (s, sc) => s + sc.issues.length);
    final errorCount = screens.fold(
        0, (s, sc) => s + sc.issues.where((i) => i.severity == 'error').length);
    final warnCount = screens.fold(0,
        (s, sc) => s + sc.issues.where((i) => i.severity == 'warning').length);
    final dateStr = '${timestamp.day}/${timestamp.month}/${timestamp.year} '
        '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}';

    final screenCards = screens.map(_buildScreenCard).join('\n');
    final riskRows = knownRisks.map(_buildRiskRow).join('\n');
    final riskSection = knownRisks.isEmpty
        ? '<p style="color:#6b7280;font-style:italic;">No static analysis bugs detected. 🎉</p>'
        : '<table class="risk-table"><thead><tr>'
            '<th>File</th><th>Field</th><th>Problem</th><th>Fix</th>'
            '</tr></thead><tbody>$riskRows</tbody></table>';

    // Arc SVG for health score gauge
    final arcPercent = score / 100.0;
    final arcDash = (arcPercent * 283).toStringAsFixed(1); // 2*pi*45 ≈ 283
    final arcGap = (283 - double.parse(arcDash)).toStringAsFixed(1);

    return '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Dangi Doctor Report — $projectName</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: #f8fafc;
    color: #1e293b;
    line-height: 1.6;
  }
  /* ── Header ─────────────────────────────── */
  .header {
    background: linear-gradient(135deg, #0f172a 0%, #1e3a5f 100%);
    color: white;
    padding: 2.5rem 3rem;
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 1.5rem;
  }
  .header-left h1 { font-size: 1.8rem; font-weight: 700; letter-spacing: -0.5px; }
  .header-left .subtitle { color: #94a3b8; font-size: 0.9rem; margin-top: 0.25rem; }
  .header-right { text-align: right; }
  .header-right .date { color: #94a3b8; font-size: 0.85rem; }
  /* ── Score gauge ─────────────────────────── */
  .gauge-wrap {
    display: flex; align-items: center; gap: 1rem;
  }
  .gauge-label { font-size: 0.8rem; color: #94a3b8; text-align: center; }
  .gauge-number { font-size: 2rem; font-weight: 800; color: $scoreColor; }
  /* ── Summary cards ───────────────────────── */
  .summary-strip {
    display: flex;
    gap: 1rem;
    padding: 1.5rem 3rem;
    background: white;
    border-bottom: 1px solid #e2e8f0;
    flex-wrap: wrap;
  }
  .stat-card {
    flex: 1; min-width: 140px;
    background: #f8fafc;
    border: 1px solid #e2e8f0;
    border-radius: 10px;
    padding: 1rem 1.25rem;
    text-align: center;
  }
  .stat-card .stat-num { font-size: 1.8rem; font-weight: 700; }
  .stat-card .stat-lbl { font-size: 0.75rem; color: #64748b; text-transform: uppercase; letter-spacing: 0.5px; margin-top: 0.2rem; }
  /* ── Main layout ─────────────────────────── */
  .content { max-width: 1200px; margin: 2rem auto; padding: 0 2rem; }
  .section-title {
    font-size: 1.1rem; font-weight: 700;
    color: #0f172a; margin-bottom: 1rem;
    display: flex; align-items: center; gap: 0.5rem;
    border-bottom: 2px solid #e2e8f0; padding-bottom: 0.5rem;
  }
  /* ── Screen cards ────────────────────────── */
  .screens-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(340px, 1fr));
    gap: 1.25rem;
    margin-bottom: 2.5rem;
  }
  .screen-card {
    background: white;
    border: 1px solid #e2e8f0;
    border-radius: 12px;
    overflow: hidden;
    box-shadow: 0 1px 3px rgba(0,0,0,0.06);
    transition: box-shadow 0.2s;
  }
  .screen-card:hover { box-shadow: 0 4px 12px rgba(0,0,0,0.1); }
  .screen-card-header {
    padding: 1rem 1.25rem;
    display: flex; justify-content: space-between; align-items: flex-start;
    border-bottom: 1px solid #f1f5f9;
  }
  .screen-name { font-weight: 700; font-size: 0.95rem; word-break: break-word; }
  .screen-via { font-size: 0.72rem; color: #94a3b8; margin-top: 0.2rem; }
  .grade-badge {
    font-size: 1.4rem; font-weight: 800;
    width: 2.4rem; height: 2.4rem;
    border-radius: 8px;
    display: flex; align-items: center; justify-content: center;
    color: white; flex-shrink: 0;
  }
  .screen-card-meta {
    padding: 0.75rem 1.25rem;
    display: flex; gap: 1.25rem;
    font-size: 0.8rem; color: #64748b;
    border-bottom: 1px solid #f1f5f9;
    flex-wrap: wrap;
  }
  .meta-item strong { color: #0f172a; }
  .screen-card-issues { padding: 0.75rem 1.25rem; }
  .issue-row {
    display: flex; align-items: flex-start; gap: 0.5rem;
    font-size: 0.8rem; padding: 0.3rem 0;
    border-bottom: 1px solid #f8fafc;
  }
  .issue-row:last-child { border-bottom: none; }
  .sev-dot {
    width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; margin-top: 5px;
  }
  .issue-msg { color: #334155; }
  .issue-loc { color: #94a3b8; font-size: 0.72rem; }
  .no-issues { font-size: 0.8rem; color: #22c55e; padding: 0.5rem 0; }
  /* ── Risk table ──────────────────────────── */
  .risk-table {
    width: 100%; border-collapse: collapse; font-size: 0.83rem;
    margin-bottom: 2.5rem;
  }
  .risk-table th {
    background: #f1f5f9; text-align: left; padding: 0.6rem 0.9rem;
    color: #475569; font-weight: 600; font-size: 0.75rem;
    text-transform: uppercase; letter-spacing: 0.4px;
  }
  .risk-table td { padding: 0.75rem 0.9rem; border-bottom: 1px solid #e2e8f0; vertical-align: top; }
  .risk-table tr:hover td { background: #f8fafc; }
  .risk-file { font-family: monospace; color: #6366f1; }
  .risk-field { font-family: monospace; font-weight: 600; }
  .risk-fix { font-family: monospace; font-size: 0.75rem; background: #f1f5f9; padding: 0.5rem; border-radius: 6px; white-space: pre-wrap; }
  /* ── Footer ──────────────────────────────── */
  .footer { text-align: center; padding: 2rem; color: #94a3b8; font-size: 0.8rem; border-top: 1px solid #e2e8f0; margin-top: 1rem; }
</style>
</head>
<body>

<!-- ── Header ───────────────────────────────────────── -->
<div class="header">
  <div class="header-left">
    <h1>🩺 Dangi Doctor</h1>
    <div class="subtitle">Flutter App Health Report &nbsp;·&nbsp; $projectName</div>
  </div>
  <div class="header-right">
    <div class="gauge-wrap">
      <div>
        <svg width="70" height="70" viewBox="0 0 100 100">
          <circle cx="50" cy="50" r="45" fill="none" stroke="#1e293b" stroke-width="10"/>
          <circle cx="50" cy="50" r="45" fill="none"
            stroke="$scoreColor" stroke-width="10"
            stroke-dasharray="$arcDash $arcGap"
            stroke-linecap="round"
            transform="rotate(-90 50 50)"/>
        </svg>
      </div>
      <div>
        <div class="gauge-number">$score</div>
        <div class="gauge-label">Health<br>Score</div>
      </div>
    </div>
    <div class="date">Generated $dateStr</div>
  </div>
</div>

<!-- ── Summary strip ─────────────────────────────────── -->
<div class="summary-strip">
  <div class="stat-card">
    <div class="stat-num" style="color:#6366f1">${screens.length}</div>
    <div class="stat-lbl">Screens crawled</div>
  </div>
  <div class="stat-card">
    <div class="stat-num" style="color:#ef4444">$errorCount</div>
    <div class="stat-lbl">Errors</div>
  </div>
  <div class="stat-card">
    <div class="stat-num" style="color:#f59e0b">$warnCount</div>
    <div class="stat-lbl">Warnings</div>
  </div>
  <div class="stat-card">
    <div class="stat-num" style="color:#f97316">${knownRisks.length}</div>
    <div class="stat-lbl">Static bugs</div>
  </div>
  <div class="stat-card">
    <div class="stat-num" style="color:#0ea5e9">$totalIssues</div>
    <div class="stat-lbl">Total issues</div>
  </div>
</div>

<!-- ── Main content ──────────────────────────────────── -->
<div class="content">

  <div class="section-title">📱 Screens</div>
  <div class="screens-grid">
$screenCards
  </div>

  <div class="section-title">⚠️ Static Analysis Bugs</div>
  $riskSection

</div>

<div class="footer">
  Generated by <strong>Dangi Doctor</strong> — your Flutter app's personal physician 🩺
</div>

</body>
</html>''';
  }

  static String _buildScreenCard(DiscoveredScreen screen) {
    final grade = screen.performance?.grade ?? 'N/A';
    final gradeColor = _gradeColor(grade);
    final via = screen.navigatedVia != null
        ? '<div class="screen-via">via ${_esc(screen.navigatedVia!)}</div>'
        : '';

    final avgBuild = screen.performance?.avgBuildMs.toStringAsFixed(1) ?? '–';
    final jankRate = screen.performance?.jankRate.toStringAsFixed(0) ?? '–';
    final memKb = screen.performance != null
        ? '${(screen.performance!.memoryKb / 1024).toStringAsFixed(1)} MB'
        : '–';

    final issueRows = screen.issues.isEmpty
        ? '<div class="no-issues">✓ No issues detected</div>'
        : screen.issues.map((i) {
            final color = _severityColor(i.severity);
            final loc = i.file != null
                ? '<span class="issue-loc"> (${_esc(i.file!.split('/').last)}:${i.line})</span>'
                : '';
            return '<div class="issue-row">'
                '<div class="sev-dot" style="background:$color"></div>'
                '<div><span class="issue-msg">${_esc(i.message)}</span>$loc</div>'
                '</div>';
          }).join('\n');

    return '''    <div class="screen-card">
      <div class="screen-card-header">
        <div>
          <div class="screen-name">${_esc(screen.name)}</div>
          $via
        </div>
        <div class="grade-badge" style="background:$gradeColor">$grade</div>
      </div>
      <div class="screen-card-meta">
        <div class="meta-item">Widgets: <strong>${screen.totalWidgets}</strong></div>
        <div class="meta-item">Depth: <strong>${screen.maxDepth}</strong></div>
        <div class="meta-item">Build: <strong>${avgBuild}ms</strong></div>
        <div class="meta-item">Jank: <strong>$jankRate%</strong></div>
        <div class="meta-item">Mem: <strong>$memKb</strong></div>
      </div>
      <div class="screen-card-issues">
$issueRows
      </div>
    </div>''';
  }

  static String _buildRiskRow(KnownRisk risk) {
    final fixHtml = _esc(risk.suggestedFix);
    return '''      <tr>
        <td><span class="risk-file">${_esc(risk.file)}:${risk.line}</span></td>
        <td><span class="risk-field">${_esc(risk.fieldName)}</span></td>
        <td>${_esc(risk.description)}</td>
        <td><pre class="risk-fix">$fixHtml</pre></td>
      </tr>''';
  }
}
