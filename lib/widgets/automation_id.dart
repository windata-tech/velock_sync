import 'package:flutter/widgets.dart';

/// Publishes a widget's string key as its platform accessibility identifier
/// (iOS `accessibilityIdentifier`, Android view resource name), so UI
/// automation can find a control by the same key widget tests already use
/// instead of matching translated, frequently edited copy.
///
/// Identifiers are never read aloud. The node is a container so the control's
/// own semantics (label, button flag, tap action) merge into the node that
/// carries the identifier rather than into some ancestor.
Widget withAutomationId(Key? key, Widget child) {
  if (key case ValueKey<String>(:final value)) {
    return Semantics(container: true, identifier: value, child: child);
  }
  return child;
}
