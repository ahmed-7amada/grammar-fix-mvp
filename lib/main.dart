import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:fllama/fllama.dart';
import 'package:dio/dio.dart';

// Platform-specific imports
import 'platform_helper_stub.dart'
    if (dart.library.io) 'platform_helper_io.dart'
    if (dart.library.html) 'platform_helper_web.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Grammar Fix MVP',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const GrammarFixScreen(),
    );
  }
}

class GrammarFixScreen extends StatefulWidget {
  const GrammarFixScreen({super.key});

  @override
  State<GrammarFixScreen> createState() => _GrammarFixScreenState();
}

class _GrammarFixScreenState extends State<GrammarFixScreen> {
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _outputController = TextEditingController();

  bool _isDownloading = false;
  bool _isModelReady = false;
  bool _isProcessing = false;
  bool _isModelLoading = false;  // Track model loading state
  double _downloadProgress = 0.0;
  double _loadingProgress = 0.0;  // Track loading progress (0.0 to 1.0)
  String _statusMessage = 'Model not downloaded';

  // Tone adjustment options
  String _selectedTone = 'Formal';
  final List<String> _toneOptions = [
    'Formal',
    'Friendly',
    'Professional',
    'Casual',
    'Confident',
    'Empathetic',
  ];

  // Text statistics
  int _wordCount = 0;
  int _charCount = 0;
  int _paragraphCount = 0;
  int _sentenceCount = 0;

  String? _modelPath;

  // Mobile: Download GGUF model
  static const String modelUrl =
    'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf';
  static const String modelFilename = 'llama-3.2-1b-q4.gguf';

  // Web: MLC model ID (model downloads automatically via MLC)
  static const String webModelId = 'Llama-3.2-1B-Instruct-q4f16_1-MLC';

  @override
  void initState() {
    super.initState();
    // Add listener for real-time text statistics
    _inputController.addListener(_updateTextStats);
    if (kIsWeb) {
      _initializeWebModel();
    } else {
      _checkModelExists();
    }
  }

  void _updateTextStats() {
    final text = _inputController.text;
    setState(() {
      // Character count (including spaces)
      _charCount = text.length;

      // Word count
      _wordCount = text.trim().isEmpty
          ? 0
          : text.trim().split(RegExp(r'\s+')).length;

      // Sentence count (split by . ! ?)
      _sentenceCount = text.trim().isEmpty
          ? 0
          : RegExp(r'[.!?]+').allMatches(text).length;
      if (_sentenceCount == 0 && text.trim().isNotEmpty) {
        _sentenceCount = 1; // Count as 1 sentence if no punctuation
      }

      // Paragraph count (split by double newlines or single newlines)
      _paragraphCount = text.trim().isEmpty
          ? 0
          : text.trim().split(RegExp(r'\n\s*\n|\n')).where((p) => p.trim().isNotEmpty).length;
      if (_paragraphCount == 0 && text.trim().isNotEmpty) {
        _paragraphCount = 1;
      }
    });
  }

  void _initializeWebModel() {
    setState(() {
      _modelPath = webModelId;
      _isModelReady = true;
      _statusMessage = 'Ready! Model will download on first use (WebGPU)';
    });
  }

  // Web: Use MLC WebGPU inference (fast: 40-70 tokens/sec)
  // Mobile: Use regular fllamaChat (GGUF files)
  Future<void> _runInference({
    required OpenAiRequest request,
    required void Function(String response, bool done) onResponse,
  }) async {
    if (kIsWeb) {
      // Use MLC WebGPU for fast web inference
      await fllamaChatMlcWeb(
        request,
        (downloadProgress, loadingProgress) {
          // Model loading progress callback
          setState(() {
            _isModelLoading = true;
            _downloadProgress = downloadProgress;
            _loadingProgress = loadingProgress;
            if (downloadProgress < 1.0) {
              _statusMessage = 'Downloading model: ${(downloadProgress * 100).toInt()}%';
            } else if (loadingProgress < 1.0) {
              _statusMessage = 'Loading model into GPU: ${(loadingProgress * 100).toInt()}%';
            } else {
              _isModelLoading = false;
              _statusMessage = 'Model ready! (WebGPU accelerated)';
            }
          });
        },
        (response, responseJson, done) {
          // Inference response callback
          onResponse(response, done);
        },
      );
    } else {
      // Use regular GGUF inference on mobile
      await fllamaChat(request, (response, responseJson, done) {
        // Clean Llama 3.2 chat template tokens from response
        String cleanResponse = response
            .replaceAll(RegExp(r'<\|eot_id\|>'), '')
            .replaceAll(RegExp(r'<\|start_header_id\|>'), '')
            .replaceAll(RegExp(r'<\|end_header_id\|>'), '')
            .replaceAll(RegExp(r'\b(system|user|assistant)\b'), '')
            .trim();
        onResponse(cleanResponse, done);
      });
    }
  }

  @override
  void dispose() {
    _inputController.removeListener(_updateTextStats);
    _inputController.dispose();
    _outputController.dispose();
    super.dispose();
  }

  // Get model path (uses platform-specific helper)
  Future<String> _getModelPath() async {
    if (kIsWeb) return webModelId;
    final path = await getModelFilePath(modelFilename);
    return path ?? webModelId;
  }

  // Mobile only: Check if model file exists
  Future<void> _checkModelExists() async {
    if (kIsWeb) return;
    final modelPath = await _getModelPath();
    final exists = await modelFileExists(modelPath);

    if (exists) {
      setState(() {
        _modelPath = modelPath;
        _statusMessage = 'Model ready. Initializing...';
      });
      await _initializeModel();
    } else {
      setState(() {
        _statusMessage = 'Model not downloaded (~700 MB)';
      });
    }
  }

  // Mobile only: Download model
  Future<void> _downloadModel() async {
    if (kIsWeb) return;
    setState(() {
      _isDownloading = true;
      _statusMessage = 'Downloading model...';
      _downloadProgress = 0.0;
    });

    try {
      final modelPath = await _getModelPath();
      final dio = Dio();

      await dio.download(
        modelUrl,
        modelPath,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            setState(() {
              _downloadProgress = received / total;
              _statusMessage = 'Downloading: ${(received / 1024 / 1024).toStringAsFixed(1)} MB / ${(total / 1024 / 1024).toStringAsFixed(1)} MB';
            });
          }
        },
      );

      setState(() {
        _modelPath = modelPath;
        _statusMessage = 'Download complete. Initializing model...';
      });

      await _initializeModel();

    } catch (e) {
      setState(() {
        _statusMessage = 'Download failed: $e';
        _isDownloading = false;
      });
    }
  }

  Future<void> _initializeModel() async {
    try {
      if (_modelPath == null) return;

      // With fllama, the model loads automatically when fllamaChat is called
      // We just need to mark it as ready since the file exists
      setState(() {
        _isModelReady = true;
        _isDownloading = false;
        _statusMessage = kIsWeb
            ? 'Web model ready! (Note: Web is slower ~2 tokens/sec)'
            : 'Model ready!';
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Model initialization failed: $e';
        _isDownloading = false;
        _isModelReady = false;
      });
    }
  }

  Future<void> _rewriteText() async {
    if (!_isModelReady) {
      _showError('Model is not ready yet');
      return;
    }

    final inputText = _inputController.text.trim();
    if (inputText.isEmpty) {
      _showError('Please enter some text');
      return;
    }

    setState(() {
      _isProcessing = true;
      _outputController.text = kIsWeb ? 'Loading model & rewriting...' : 'Rewriting...';
      if (kIsWeb) {
        _statusMessage = 'Initializing...';
      }
    });

    try {
      final request = OpenAiRequest(
        maxTokens: 512,
        messages: [
          Message(
            Role.system,
            'You are a professional writing assistant. Your task is to completely rewrite and improve the text provided by the user. Make it clearer, more engaging, and professionally written while preserving the original meaning. Return ONLY the rewritten text without any explanations.',
          ),
          Message(
            Role.user,
            'Rewrite the following text: $inputText',
          ),
        ],
        modelPath: _modelPath!,
        temperature: 0.7,
        topP: 0.9,
      );

      await _runInference(
        request: request,
        onResponse: (response, done) {
          if (done) {
            print('✅ Rewrite completed');
            print('Final result: $response');
            setState(() {
              _outputController.text = response;
              _isProcessing = false;
              _statusMessage = kIsWeb ? 'Web model ready! (WebGPU accelerated)' : 'Model ready!';
            });
          } else {
            print('Streaming: $response');
            setState(() {
              _outputController.text = response;
            });
          }
        },
      );
    } catch (e) {
      setState(() {
        _outputController.text = 'Error: $e';
        _isProcessing = false;
      });
    }
  }

  Future<void> _adjustTone() async {
    if (!_isModelReady) {
      _showError('Model is not ready yet');
      return;
    }

    final inputText = _inputController.text.trim();
    if (inputText.isEmpty) {
      _showError('Please enter some text');
      return;
    }

    setState(() {
      _isProcessing = true;
      _outputController.text = kIsWeb ? 'Loading model & adjusting tone...' : 'Adjusting tone...';
      if (kIsWeb) {
        _statusMessage = 'Initializing...';
      }
    });

    // Define tone descriptions for better prompts
    final toneDescriptions = {
      'Formal': 'formal, professional, and suitable for business or academic contexts',
      'Friendly': 'warm, approachable, and conversational while remaining respectful',
      'Professional': 'polished, competent, and business-appropriate',
      'Casual': 'relaxed, informal, and easy-going like talking to a friend',
      'Confident': 'assertive, self-assured, and decisive',
      'Empathetic': 'understanding, compassionate, and emotionally supportive',
    };

    final toneDesc = toneDescriptions[_selectedTone] ?? _selectedTone.toLowerCase();

    try {
      final request = OpenAiRequest(
        maxTokens: 512,
        messages: [
          Message(
            Role.system,
            'You are a tone adjustment assistant. Your task is to rewrite the text to have a $_selectedTone tone. Make it sound $toneDesc. Preserve the original meaning but adjust the word choice, sentence structure, and style to match the desired tone. Return ONLY the adjusted text without any explanations.',
          ),
          Message(
            Role.user,
            'Rewrite this text in a $_selectedTone tone: $inputText',
          ),
        ],
        modelPath: _modelPath!,
        temperature: 0.6,
        topP: 0.9,
      );

      await _runInference(
        request: request,
        onResponse: (response, done) {
          if (done) {
            print('✅ Tone adjustment completed');
            print('Final result: $response');
            setState(() {
              _outputController.text = response;
              _isProcessing = false;
              _statusMessage = kIsWeb ? 'Web model ready! (WebGPU accelerated)' : 'Model ready!';
            });
          } else {
            print('Streaming: $response');
            setState(() {
              _outputController.text = response;
            });
          }
        },
      );
    } catch (e) {
      setState(() {
        _outputController.text = 'Error: $e';
        _isProcessing = false;
      });
    }
  }

  Future<void> _analyzeReaderReactions() async {
    if (!_isModelReady) {
      _showError('Model is not ready yet');
      return;
    }

    final inputText = _inputController.text.trim();
    if (inputText.isEmpty) {
      _showError('Please enter some text');
      return;
    }

    setState(() {
      _isProcessing = true;
      _outputController.text = kIsWeb ? 'Loading model & analyzing...' : 'Analyzing...';
      if (kIsWeb) {
        _statusMessage = 'Initializing...';
      }
    });

    try {
      final request = OpenAiRequest(
        maxTokens: 512,
        messages: [
          Message(
            Role.system,
            '''You are a writing analyst that predicts reader reactions. Analyze the text and provide:

1. TONE DETECTED: List 2-3 tones (e.g., Formal, Friendly, Urgent, Cold, Warm)
2. READER MAY FEEL: How readers might emotionally react (e.g., Informed, Confused, Motivated, Defensive)
3. STRENGTHS: What works well in the writing (1-2 points)
4. SUGGESTIONS: How to improve impact (1-2 specific tips)

Keep your response concise and use bullet points.''',
          ),
          Message(
            Role.user,
            'Analyze reader reactions for this text:\n\n$inputText',
          ),
        ],
        modelPath: _modelPath!,
        temperature: 0.5,
        topP: 0.9,
      );

      await _runInference(
        request: request,
        onResponse: (response, done) {
          if (done) {
            print('✅ Reader reactions analysis completed');
            print('Final result: $response');
            setState(() {
              _outputController.text = response;
              _isProcessing = false;
              _statusMessage = kIsWeb ? 'Web model ready! (WebGPU accelerated)' : 'Model ready!';
            });
          } else {
            print('Streaming: $response');
            setState(() {
              _outputController.text = response;
            });
          }
        },
      );
    } catch (e) {
      setState(() {
        _outputController.text = 'Error: $e';
        _isProcessing = false;
      });
    }
  }

  Future<void> _fixGrammar() async {
    if (!_isModelReady) {
      _showError('Model is not ready yet');
      return;
    }

    final inputText = _inputController.text.trim();
    if (inputText.isEmpty) {
      _showError('Please enter some text');
      return;
    }

    setState(() {
      _isProcessing = true;
      _outputController.text = kIsWeb ? 'Loading model & processing...' : 'Processing...';
      if (kIsWeb) {
        _statusMessage = 'Initializing...';
      }
    });

    try {
      // Create chat request with system and user messages
      final request = OpenAiRequest(
        maxTokens: 256,
        messages: [
          Message(
            Role.system,
            'You are a grammar correction assistant. Your task is to correct grammar, spelling, and punctuation errors in the text provided by the user. Return ONLY the corrected text without any explanations or additional commentary.',
          ),
          Message(
            Role.user,
            'Correct the following text: $inputText',
          ),
        ],
        modelPath: _modelPath!,
        temperature: 0.1,
        topP: 0.95,
      );

      await _runInference(
        request: request,
        onResponse: (response, done) {
          if (done) {
            print('✅ Grammar correction completed');
            print('Final result: $response');
            setState(() {
              _outputController.text = response;
              _isProcessing = false;
              _statusMessage = kIsWeb ? 'Web model ready! (WebGPU accelerated)' : 'Model ready!';
            });
          } else {
            print('Streaming: $response');
            setState(() {
              _outputController.text = response;
            });
          }
        },
      );
    } catch (e) {
      setState(() {
        _outputController.text = 'Error: $e';
        _isProcessing = false;
      });
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Widget _buildStatItem(String label, int count, IconData icon) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: Colors.grey[600]),
        const SizedBox(height: 4),
        Text(
          count.toString(),
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey[600],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Grammar Fix MVP'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Status Card
              Card(
                color: _isModelReady ? Colors.green[50] : Colors.orange[50],
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      Text(
                        _statusMessage,
                        style: const TextStyle(fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                      // Show progress bar for downloading or loading
                      if (_isDownloading || _isModelLoading || _isProcessing) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: _isDownloading
                              ? _downloadProgress
                              : (_isModelLoading ? _loadingProgress : null),
                        ),
                      ],
                      // Only show download button on mobile
                      if (!kIsWeb && !_isModelReady && !_isDownloading) ...[
                        const SizedBox(height: 8),
                        ElevatedButton(
                          onPressed: _downloadModel,
                          child: const Text('Download Model (~700 MB)'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Input Text Field
              const Text('Input Text:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _inputController,
                maxLines: 5,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Enter text to fix grammar...\ne.g., "I goes to school yesterday"',
                ),
                enabled: _isModelReady,
              ),
              const SizedBox(height: 8),

              // Text Statistics Card
              Card(
                color: Colors.grey[100],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildStatItem('Words', _wordCount, Icons.text_fields),
                      _buildStatItem('Characters', _charCount, Icons.abc),
                      _buildStatItem('Sentences', _sentenceCount, Icons.short_text),
                      _buildStatItem('Paragraphs', _paragraphCount, Icons.subject),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Action Buttons Row
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isModelReady && !_isProcessing ? _fixGrammar : null,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                      ),
                      child: Text(
                        _isProcessing ? 'Processing...' : 'Fix Grammar',
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isModelReady && !_isProcessing ? _rewriteText : null,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        backgroundColor: Colors.deepPurple,
                        foregroundColor: Colors.white,
                      ),
                      child: Text(
                        _isProcessing ? 'Processing...' : 'Rewrite',
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Tone Adjustment Row
              Row(
                children: [
                  // Tone Dropdown
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.teal, width: 2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _selectedTone,
                        icon: const Icon(Icons.arrow_drop_down, color: Colors.teal),
                        style: const TextStyle(color: Colors.teal, fontSize: 16),
                        onChanged: _isProcessing ? null : (String? newValue) {
                          if (newValue != null) {
                            setState(() {
                              _selectedTone = newValue;
                            });
                          }
                        },
                        items: _toneOptions.map<DropdownMenuItem<String>>((String value) {
                          return DropdownMenuItem<String>(
                            value: value,
                            child: Text(value),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Adjust Tone Button
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isModelReady && !_isProcessing ? _adjustTone : null,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        backgroundColor: Colors.teal,
                        foregroundColor: Colors.white,
                      ),
                      child: Text(
                        _isProcessing ? 'Processing...' : 'Adjust Tone',
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Reader Reactions Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isModelReady && !_isProcessing ? _analyzeReaderReactions : null,
                  icon: const Icon(Icons.psychology),
                  label: Text(
                    _isProcessing ? 'Processing...' : 'Reader Reactions',
                    style: const TextStyle(fontSize: 16),
                  ),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.all(16),
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Output Text Field
              const Text('Corrected Text:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              SizedBox(
                height: 200,
                child: TextField(
                  controller: _outputController,
                  maxLines: null,
                  expands: true,
                  readOnly: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Corrected text will appear here...',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
