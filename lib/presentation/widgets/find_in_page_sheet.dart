import 'package:flutter/material.dart';

/// Current state of the find-in-page search.
class FindState {
  FindState({this.query = '', this.matchCount = 0, this.currentIndex = -1});

  final String query;
  final int matchCount;
  final int currentIndex;

  FindState copyWith({String? query, int? matchCount, int? currentIndex}) {
    return FindState(
      query: query ?? this.query,
      matchCount: matchCount ?? this.matchCount,
      currentIndex: currentIndex ?? this.currentIndex,
    );
  }
}

/// Persistent bottom sheet for searching text within the current page.
class FindInPageSheet extends StatefulWidget {
  const FindInPageSheet({
    super.key,
    required this.stateNotifier,
    required this.onQueryChanged,
    required this.onPrevious,
    required this.onNext,
  });

  final ValueNotifier<FindState> stateNotifier;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  static PersistentBottomSheetController show({
    required BuildContext context,
    required ValueNotifier<FindState> stateNotifier,
    required ValueChanged<String> onQueryChanged,
    required VoidCallback onPrevious,
    required VoidCallback onNext,
  }) {
    return showBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => FindInPageSheet(
        stateNotifier: stateNotifier,
        onQueryChanged: onQueryChanged,
        onPrevious: onPrevious,
        onNext: onNext,
      ),
    );
  }

  @override
  State<FindInPageSheet> createState() => _FindInPageSheetState();
}

class _FindInPageSheetState extends State<FindInPageSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.stateNotifier.value.query);
    widget.stateNotifier.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    widget.stateNotifier.removeListener(_onStateChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    final state = widget.stateNotifier.value;
    if (_controller.text != state.query) {
      _controller.text = state.query;
      _controller.selection = TextSelection.collapsed(offset: state.query.length);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ValueListenableBuilder<FindState>(
      valueListenable: widget.stateNotifier,
      builder: (context, state, _) {
        final hasQuery = state.query.isNotEmpty;
        final matchLabel = hasQuery
            ? state.matchCount == 0
                ? 'No matches'
                : '${state.currentIndex + 1} / ${state.matchCount}'
            : '';

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        autofocus: true,
                        decoration: InputDecoration(
                          hintText: 'Find in page',
                          prefixIcon: const Icon(Icons.search),
                          filled: true,
                          fillColor: colors.surfaceContainerHighest,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        onChanged: widget.onQueryChanged,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_up),
                      tooltip: 'Previous',
                      onPressed: widget.onPrevious,
                    ),
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down),
                      tooltip: 'Next',
                      onPressed: widget.onNext,
                    ),
                  ],
                ),
                if (matchLabel.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 16, top: 8),
                    child: Text(
                      matchLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
