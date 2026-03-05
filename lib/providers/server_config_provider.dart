import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/server_config.dart';
import '../services/server_service.dart';

/// Provider for managing AI server configuration
class ServerConfigProvider extends ChangeNotifier {
  static const String _configKey = 'server_config';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  ServerConfig? _config;
  bool _isServerRunning = false;
  bool _isLoading = true;

  ServerConfig? get config => _config;
  bool get isServerRunning => _isServerRunning;
  bool get isLoading => _isLoading;
  bool get isConfigured => _config?.isValid ?? false;

  ServerConfigProvider() {
    _loadConfig();
  }

  /// Load config from secure storage
  Future<void> _loadConfig() async {
    try {
      final jsonStr = await _secureStorage.read(key: _configKey);
      if (jsonStr != null) {
        final json = jsonDecode(jsonStr);
        _config = ServerConfig.fromJson(json);
      }
    } catch (e) {
      debugPrint('Error loading server config: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Save config to secure storage
  Future<void> saveConfig(ServerConfig config) async {
    try {
      _config = config;
      await _secureStorage.write(
        key: _configKey,
        value: jsonEncode(config.toJson()),
      );
      notifyListeners();

      // Update running service if active
      if (_isServerRunning) {
        ServerService().updateConfig(config);
      }
    } catch (e) {
      debugPrint('Error saving server config: $e');
    }
  }

  /// Update individual fields
  Future<void> updateGroqApiKey(String apiKey) async {
    final newConfig = (_config ?? ServerConfig(
      groqApiKey: '',
      typecastApiKey: '',
      mem0ApiKey: '',
    )).copyWith(groqApiKey: apiKey);
    await saveConfig(newConfig);
  }

  Future<void> updateTypecastApiKey(String apiKey) async {
    final newConfig = (_config ?? ServerConfig(
      groqApiKey: '',
      typecastApiKey: '',
      mem0ApiKey: '',
    )).copyWith(typecastApiKey: apiKey);
    await saveConfig(newConfig);
  }

  Future<void> updateMem0ApiKey(String apiKey) async {
    final newConfig = (_config ?? ServerConfig(
      groqApiKey: '',
      typecastApiKey: '',
      mem0ApiKey: '',
    )).copyWith(mem0ApiKey: apiKey);
    await saveConfig(newConfig);
  }

  Future<void> updateLlmModel(String model) async {
    if (_config == null) return;
    await saveConfig(_config!.copyWith(llmModel: model));
  }

  Future<void> updateSttModel(String model) async {
    if (_config == null) return;
    await saveConfig(_config!.copyWith(sttModel: model));
  }

  Future<void> updateTtsVoiceId(String voiceId) async {
    if (_config == null) return;
    await saveConfig(_config!.copyWith(ttsVoiceId: voiceId));
  }

  Future<void> updateSystemPrompt(String prompt) async {
    if (_config == null) return;
    await saveConfig(_config!.copyWith(systemPrompt: prompt));
  }

  /// Start the AI server
  Future<bool> startServer() async {
    if (_config == null || !_config!.isValid) {
      debugPrint('Cannot start server: config is invalid');
      return false;
    }

    try {
      await ServerService().start(_config!);
      _isServerRunning = true;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error starting server: $e');
      return false;
    }
  }

  /// Stop the AI server
  Future<void> stopServer() async {
    try {
      await ServerService().stop();
      _isServerRunning = false;
      notifyListeners();
    } catch (e) {
      debugPrint('Error stopping server: $e');
    }
  }

  /// Check if server is running
  Future<void> checkServerStatus() async {
    _isServerRunning = await ServerService().isRunning();
    notifyListeners();
  }

  /// Clear all config
  Future<void> clearConfig() async {
    await _secureStorage.delete(key: _configKey);
    _config = null;
    notifyListeners();
  }
}
