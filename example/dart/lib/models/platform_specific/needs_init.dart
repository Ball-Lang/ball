import 'dart:async';

mixin NeedsInit {
  FutureOr<void> init();
}
