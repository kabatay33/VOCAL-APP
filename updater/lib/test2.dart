import 'dart:io';

void main() {
  final f = File('C:\\Users\\DUTAMETA\\Desktop\\test2.log');
  f.writeAsStringSync('${DateTime.now()} TEST2 OK\n');
  print('TEST2 OK');
}
