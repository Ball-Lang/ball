import 'dart:async';

typedef BallSyncFunction = Map<String, dynamic> Function(
  Map<String, dynamic> inputs,
);
typedef BallAsyncFunction = FutureOr<Map<String, dynamic>> Function(
  Map<String, dynamic> inputs,
);

class BallConsts {
  /// the key: `_`
  static const singleOutput = '_';
}
