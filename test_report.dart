import 'package:dangi_doctor/report/html_report.dart';

void main() async {
  await HtmlReportGenerator.generate(
    screens: [],
    knownRisks: [],
    projectPath: '/Users/abhishek/Desktop/reflex-flutter',
    projectName: 'reflex-flutter',
  );
}
