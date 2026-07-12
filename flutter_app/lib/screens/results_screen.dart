import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/api_client.dart';
import '../models/models.dart';

class ResultsScreen extends StatefulWidget {
  final ApiClient apiClient;
  final String businessProfileId;

  const ResultsScreen({
    super.key,
    required this.apiClient,
    required this.businessProfileId,
  });

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  String? _projectId;
  Project? _project;
  Timer? _pollTimer;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _startLogoGeneration();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _startLogoGeneration() async {
    try {
      final projectId = await widget.apiClient.createLogoProject(
        businessProfileId: widget.businessProfileId,
        stylePrompt: 'clean, modern, minimal geometric mark',
      );
      setState(() => _projectId = projectId);
      _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    } catch (e) {
      setState(() => _errorMessage = 'Could not start generation — $e');
    }
  }

  Future<void> _poll() async {
    if (_projectId == null) return;
    try {
      final project = await widget.apiClient.getProject(_projectId!);
      setState(() => _project = project);
      if (project.isReady || project.isFailed) {
        _pollTimer?.cancel();
      }
    } catch (e) {
      // Transient network errors during polling shouldn't stop the flow -
      // just skip this tick and try again on the next timer fire.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your brand assets')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_errorMessage != null) {
      return Center(
        child: Text(
          _errorMessage!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    }

    if (_project == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Starting generation…'),
          ],
        ),
      );
    }

    if (_project!.isInProgress) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Status: ${_project!.status}'),
            const SizedBox(height: 8),
            const Text('This usually takes a minute or two.'),
          ],
        ),
      );
    }

    if (_project!.isFailed) {
      return const Center(child: Text('Generation failed — please try again.'));
    }

    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _project!.assets.length,
      itemBuilder: (context, index) {
        final asset = _project!.assets[index];
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: CachedNetworkImage(
            imageUrl: asset.url,
            fit: BoxFit.cover,
            placeholder: (_, __) => const Center(child: CircularProgressIndicator()),
            errorWidget: (_, __, ___) => const Icon(Icons.broken_image),
          ),
        );
      },
    );
  }
}
