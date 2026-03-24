import 'dart:async';

typedef DialogTrackNavigationHandler = FutureOr<bool> Function(bool forward);
typedef DialogSelectHandler = FutureOr<bool> Function();

class _DialogMediaKeyBinding {
  final int token;
  final DialogTrackNavigationHandler onTrackNavigate;
  final DialogSelectHandler onSelect;

  const _DialogMediaKeyBinding({
    required this.token,
    required this.onTrackNavigate,
    required this.onSelect,
  });
}

class DialogMediaKeyNavigation {
  DialogMediaKeyNavigation._();

  static final List<_DialogMediaKeyBinding> _bindings =
      <_DialogMediaKeyBinding>[];
  static int _nextToken = 1;

  static int register({
    required DialogTrackNavigationHandler onTrackNavigate,
    required DialogSelectHandler onSelect,
  }) {
    final int token = _nextToken++;
    _bindings.add(
      _DialogMediaKeyBinding(
        token: token,
        onTrackNavigate: onTrackNavigate,
        onSelect: onSelect,
      ),
    );
    return token;
  }

  static void unregister(int token) {
    _bindings.removeWhere((binding) => binding.token == token);
  }

  static Future<bool> handleTrackNavigate(bool forward) async {
    if (_bindings.isEmpty) return false;
    final _DialogMediaKeyBinding active = _bindings.last;
    final bool handled = await active.onTrackNavigate(forward);
    return handled;
  }

  static Future<bool> handleSelect() async {
    if (_bindings.isEmpty) return false;
    final _DialogMediaKeyBinding active = _bindings.last;
    final bool handled = await active.onSelect();
    return handled;
  }
}
