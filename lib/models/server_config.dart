/// Configuration for the AI server services
class ServerConfig {
  final String groqApiKey;
  final String typecastApiKey;
  final String openaiApiKey; // For OpenAI TTS
  final String mem0ApiKey;
  final String? mem0UserId;
  final String llmModel;
  final String sttModel;
  final String ttsProvider; // 'edgetts', 'openai', 'typecast'
  final String ttsVoiceId;
  final String? systemPrompt;

  ServerConfig({
    required this.groqApiKey,
    this.typecastApiKey = '',
    this.openaiApiKey = '',
    this.mem0ApiKey = '',
    this.mem0UserId,
    this.llmModel = 'openai/gpt-oss-20b',
    this.sttModel = 'whisper-large-v3-turbo',
    this.ttsProvider = 'typecast',
    this.ttsVoiceId =
        'tc_65fbe54e2668bc4ddbd8b2a6', // Korean female voice for EdgeTTS
    this.systemPrompt,
  });

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      groqApiKey: json['groqApiKey'] ?? '',
      typecastApiKey: json['typecastApiKey'] ?? '',
      openaiApiKey: json['openaiApiKey'] ?? '',
      mem0ApiKey: json['mem0ApiKey'] ?? '',
      mem0UserId: json['mem0UserId'],
      llmModel: json['llmModel'] ?? 'openai/gpt-oss-20b',
      sttModel: json['sttModel'] ?? 'whisper-large-v3-turbo',
      ttsProvider: json['ttsProvider'] ?? 'typecast',
      ttsVoiceId:
          json['ttsVoiceId'] ?? '__pltHwnnS6MZTTZhSbDg3zRVCYeCJkUXETAfb4bu2vgr',
      systemPrompt: json['systemPrompt'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'groqApiKey': groqApiKey,
      'typecastApiKey': typecastApiKey,
      'openaiApiKey': openaiApiKey,
      'mem0ApiKey': mem0ApiKey,
      'mem0UserId': mem0UserId,
      'llmModel': llmModel,
      'sttModel': sttModel,
      'ttsProvider': ttsProvider,
      'ttsVoiceId': ttsVoiceId,
      'systemPrompt': systemPrompt,
    };
  }

  ServerConfig copyWith({
    String? groqApiKey,
    String? typecastApiKey,
    String? openaiApiKey,
    String? mem0ApiKey,
    String? mem0UserId,
    String? llmModel,
    String? sttModel,
    String? ttsProvider,
    String? ttsVoiceId,
    String? systemPrompt,
  }) {
    return ServerConfig(
      groqApiKey: groqApiKey ?? this.groqApiKey,
      typecastApiKey: typecastApiKey ?? this.typecastApiKey,
      openaiApiKey: openaiApiKey ?? this.openaiApiKey,
      mem0ApiKey: mem0ApiKey ?? this.mem0ApiKey,
      mem0UserId: mem0UserId ?? this.mem0UserId,
      llmModel: llmModel ?? this.llmModel,
      sttModel: sttModel ?? this.sttModel,
      ttsProvider: ttsProvider ?? this.ttsProvider,
      ttsVoiceId: ttsVoiceId ?? this.ttsVoiceId,
      systemPrompt: systemPrompt ?? this.systemPrompt,
    );
  }

  // Only Groq API key is required - EdgeTTS is free, no key needed
  bool get isValid => groqApiKey.isNotEmpty;
}
