import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/system.dart';
import '../../../data/repositories/node_repository.dart';
import '../../../domain/models/search_filters.dart';
import '../../auth/providers/auth_provider.dart';

/// The review-session hand-off — the local equivalent of the web
/// sessionStorage hand-off: the queue's card ids plus the summary label
/// the session's header wears ("All cards", "Single card", a filtered
/// summary).
class CardsSessionHandOff {
  const CardsSessionHandOff({required this.cardIds, required this.label});

  final List<String> cardIds;
  final String label;

  /// Parses `state.extra`; null for a missing/corrupt extra (the route then
  /// falls back to every card member, the web deep-link fallback).
  static CardsSessionHandOff? fromExtra(Object? extra) {
    if (extra is! Map) return null;
    final rawIds = extra['cardIds'];
    final label = extra['label'];
    if (rawIds is! List) return null;
    final cardIds = rawIds.whereType<String>().toList(growable: false);
    if (cardIds.isEmpty || label is! String) return null;
    return CardsSessionHandOff(cardIds: cardIds, label: label);
  }
}

/// The review session (`/cards/review`) — grades the hand-off queue.
///
/// Task 4 placeholder: resolves the session's card ids (the explicit
/// hand-off, else every card member — the web deep-link fallback) so the
/// route is wired end-to-end; the session UI lands in Task 7.
class ReviewSessionScreen extends StatefulWidget {
  const ReviewSessionScreen({super.key, this.cardIds, this.label});

  /// The hand-off queue; null = resolve every card member (deep-link arm).
  final List<String>? cardIds;

  /// The summary label for the session header.
  final String? label;

  @override
  State<ReviewSessionScreen> createState() => _ReviewSessionScreenState();
}

class _ReviewSessionScreenState extends State<ReviewSessionScreen> {
  List<String>? _cardIds;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _resolveIds();
  }

  Future<void> _resolveIds() async {
    final handOffIds = widget.cardIds;
    if (handOffIds != null) {
      setState(() => _cardIds = handOffIds);
      return;
    }
    // No (or corrupt) hand-off: every card-classed member — the queue
    // itself drops the future-due set (the web deep-link fallback).
    final auth = context.read<AuthProvider>();
    final dio = auth.dio;
    if (dio == null) {
      setState(() => _error = 'Review requires a synced workspace.');
      return;
    }
    try {
      final members = await NodeRepository(dio: dio, syncService: auth.syncService)
          .searchWithFilters(const SearchFilters(classUuids: [SystemClassUuids.card], limit: 500));
      if (!mounted) return;
      setState(() {
        _cardIds = members.map((node) => node.uuid).toList(growable: false);
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cardIds = _cardIds;
    return Scaffold(
      appBar: AppBar(title: const Text('Review')),
      body: _error != null
          ? Center(child: Text('Could not start the review session'))
          : cardIds == null
              ? const Center(child: CircularProgressIndicator())
              : cardIds.isEmpty
                  ? const Center(child: Text('Nothing to review'))
                  : Center(child: Text('${cardIds.length} cards')),
    );
  }
}
