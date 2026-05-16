import 'package:flutter_test/flutter_test.dart';

import 'package:discord_clone/main.dart';

void main() {
  testWidgets('App boots without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const App());
    await tester.pump();
  });
}
