import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/system.dart';
import '../../../data/repositories/node_repository.dart';
import '../../../domain/models/search_filters.dart';
import '../../auth/providers/auth_provider.dart';

/// The Cards hub — every node classed `card` (the web `/cards` route).
///
/// Task 4 placeholder: resolves the card members so the routing/navigation
/// slice is wired end-to-end; the hub UI (bucket strip, card rows,
/// algorithm toggle) lands in Task 5.
class CardsScreen extends StatefulWidget {
  const CardsScreen({super.key});

  @override
  State<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends State<CardsScreen> {
  List<String>? _memberIds;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final auth = context.read<AuthProvider>();
    final dio = auth.dio;
    if (dio == null) {
      setState(() => _error = 'Cards require a synced workspace.');
      return;
    }
    try {
      final members = await NodeRepository(dio: dio, syncService: auth.syncService)
          .searchWithFilters(const SearchFilters(classUuids: [SystemClassUuids.card], limit: 500));
      if (!mounted) return;
      setState(() {
        _memberIds = members.map((node) => node.uuid).toList(growable: false);
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final memberIds = _memberIds;
    return Scaffold(
      appBar: AppBar(title: const Text('Cards')),
      body: _error != null
          ? Center(child: Text('Could not load cards'))
          : memberIds == null
              ? const Center(child: CircularProgressIndicator())
              : memberIds.isEmpty
                  ? const Center(child: Text('No cards yet'))
                  : Center(child: Text('${memberIds.length} cards')),
    );
  }
}
