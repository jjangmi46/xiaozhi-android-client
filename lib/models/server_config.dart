/// Configuration for the AI server services
class ServerConfig {
  final String groqApiKey;
  final String typecastApiKey;
  final String mem0ApiKey;
  final String? mem0UserId;
  final String llmModel;
  final String sttModel;
  final String ttsVoiceId;
  final String? systemPrompt;

  ServerConfig({
    required this.groqApiKey,
    required this.typecastApiKey,
    required this.mem0ApiKey,
    this.mem0UserId,
    this.llmModel = 'llama-3.3-70b-versatile',
    this.sttModel = 'whisper-large-v3-turbo',
    this.ttsVoiceId = 'default',
    this.systemPrompt,
  });

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      groqApiKey: json['groqApiKey'] ?? '',
      typecastApiKey: json['typecastApiKey'] ?? '',
      mem0ApiKey: json['mem0ApiKey'] ?? '',
      mem0UserId: json['mem0UserId'],
      llmModel: json['llmModel'] ?? 'llama-3.3-70b-versatile',
      sttModel: json['sttModel'] ?? 'whisper-large-v3-turbo',
      ttsVoiceId: json['ttsVoiceId'] ?? 'default',
      systemPrompt: json['systemPrompt'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'groqApiKey': groqApiKey,
      'typecastApiKey': typecastApiKey,
      'mem0ApiKey': mem0ApiKey,
      'mem0UserId': mem0UserId,
      'llmModel': llmModel,
      'sttModel': sttModel,
      'ttsVoiceId': ttsVoiceId,
      'systemPrompt': systemPrompt,
    };
  }

  ServerConfig copyWith({
    String? groqApiKey,
    String? typecastApiKey,
    String? mem0ApiKey,
    String? mem0UserId,
    String? llmModel,
    String? sttModel,
    String? ttsVoiceId,
    String? systemPrompt,
  }) {
    return ServerConfig(
      groqApiKey: groqApiKey ?? this.groqApiKey,
      typecastApiKey: typecastApiKey ?? this.typecastApiKey,
      mem0ApiKey: mem0ApiKey ?? this.mem0ApiKey,
      mem0UserId: mem0UserId ?? this.mem0UserId,
      llmModel: llmModel ?? this.llmModel,
      sttModel: sttModel ?? this.sttModel,
      ttsVoiceId: ttsVoiceId ?? this.ttsVoiceId,
      systemPrompt: systemPrompt ?? this.systemPrompt,
    );
  }

  bool get isValid =>
      groqApiKey.isNotEmpty &&
      typecastApiKey.isNotEmpty;
}
