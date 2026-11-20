// ============================================================================
// FILE THAM CHIẾU ĐẦY ĐỦ 8 BƯỚC: eye_helper_full_reference.dart
// Kiến trúc giữ nguyên 100% với lib/main.dart từ Bước 1 đến Bước 8.
// Để chạy bản đầy đủ 8 bước ngay lập tức, bạn chỉ cần copy nội dung file này
// đè vào lib/main.dart sau khi đã điền GROQ_API_KEY vào file .env.
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:battery_plus/battery_plus.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ============================================================================
// 1. CẤU HÌNH HỆ THỐNG & HẰNG SỐ GROQ API
// ============================================================================
class AppConfig {
  static const String appName = 'EyeHelper';

  // Endpoint chuẩn OpenAI-compatible của Groq
  static const String groqChatEndpoint =
      'https://api.groq.com/openai/v1/chat/completions';
  static const String groqAudioEndpoint =
      'https://api.groq.com/openai/v1/audio/transcriptions';

  // Model Vision mặc định & dự phòng theo console.groq.com/docs/vision
  static const String defaultVisionModel = 'qwen/qwen3.8-27b';
  static const String fallbackVisionModel =
      'meta-llama/llama-4-scout-17b-16e-instruct';
  static const String defaultWhisperModel = 'whisper-large-v3-turbo';

  // Cấu hình xử lý ảnh & giới hạn tần suất (Rate Limit)
  static const int targetMaxDimensionPx = 640; // Resize cạnh dài ~640px
  static const int jpegQuality = 65; // Chất lượng JPEG 60-70
  static const int maxRequestsPerMinute = 15; // Tối đa N request/phút
  static const double sceneChangeThreshold = 14.0; // Ngưỡng khác biệt hash 8x8

  // Từ khóa nhận diện cảnh báo nguy hiểm ưu tiên 1
  static const List<String> hazardKeywords = [
    'nguy hiểm',
    'cẩn thận',
    'coi chừng',
    'dừng lại',
    'vật cản',
    'bậc thang',
    'cầu thang',
    'hố',
    'rãnh',
    'xe ',
    'ô tô',
    'xe máy',
    'vật nhọn',
    'va chạm',
  ];

  // Prompt hệ thống bắt buộc (Mục 6)
  static const String systemPrompt =
      'Bạn là đôi mắt của người khiếm thị, đang nhìn các khung hình liên tiếp từ camera điện thoại họ cầm. '
      'Chỉ trả lời bằng tiếng Việt, 1-2 câu ngắn, tự nhiên như người đi cùng. '
      'Nguy hiểm thì cảnh báo trước. '
      'Nếu cảnh không đổi so với lần trước thì trả về đúng chuỗi [IM_LANG]. '
      'Chỉ mô tả điều thật sự nhìn thấy, không bịa; không chắc thì nói không chắc. '
      'Dùng trái/phải/trước/sau và số bước chân. '
      'Không nhận diện danh tính người. '
      'Với thuốc, chỉ đọc thông tin nhìn thấy và nhắc hỏi bác sĩ hoặc dược sĩ.';

  /// Lấy API key an toàn từ --dart-define hoặc file .env (không hardcode)
  static String get groqApiKey {
    const fromDefine = String.fromEnvironment('GROQ_API_KEY');
    if (fromDefine.isNotEmpty) return fromDefine;
    return dotenv.env['GROQ_API_KEY']?.trim() ?? '';
  }

  static String get visionModel {
    const fromDefine = String.fromEnvironment('GROQ_VISION_MODEL');
    if (fromDefine.isNotEmpty) return fromDefine;
    final fromEnv = dotenv.env['GROQ_VISION_MODEL']?.trim() ?? '';
    return fromEnv.isNotEmpty ? fromEnv : defaultVisionModel;
  }
}

// ============================================================================
// 2. DỮ LIỆU KHUNG HÌNH ĐÃ LẤY MẪU (CHỈ GIỮ 1 KHUNG MỚI NHẤT TRONG RAM)
// ============================================================================
class SampledFrame {
  final Uint8List jpegBytes;
  final List<int> signature8x8; // 64 điểm độ sáng 8x8 để so sánh cảnh thay đổi
  final double meanBrightness; // Độ sáng trung bình (0..255)
  final double sharpnessScore; // Độ nét ước lượng (phát hiện rung tay)
  final DateTime timestamp;

  SampledFrame({
    required this.jpegBytes,
    required this.signature8x8,
    required this.meanBrightness,
    required this.sharpnessScore,
    required this.timestamp,
  });

  String toDataUrl() => 'data:image/jpeg;base64,${base64Encode(jpegBytes)}';
}

// ============================================================================
// 3. BỘ XỬ LÝ ẢNH CAMERA YUV420 -> JPEG 640PX + HASH 8X8 TRONG BỘ NHỚ
// ============================================================================
class FrameProcessor {
  /// Chuyển CameraImage (YUV420/BGRA8888) sang JPEG 640px + tính chữ ký 8x8
  static SampledFrame? processCameraImage(
    CameraImage cameraImage, {
    int sensorOrientation = 90,
  }) {
    try {
      final int width = cameraImage.width;
      final int height = cameraImage.height;
      if (cameraImage.planes.isEmpty) return null;

      // 1. Tính nhanh độ sáng trung bình, độ nét (Laplacian xấp xỉ) & chữ ký 8x8 từ kênh Y
      final Plane yPlane = cameraImage.planes[0];
      final Uint8List yBytes = yPlane.bytes;
      final int yRowStride = yPlane.bytesPerRow;

      final List<int> sig8x8 = List<int>.filled(64, 0);
      double totalLuma = 0;

      for (int gy = 0; gy < 8; gy++) {
        for (int gx = 0; gx < 8; gx++) {
          final int py = ((gy + 0.5) * height / 8).floor().clamp(0, height - 1);
          final int px = ((gx + 0.5) * width / 8).floor().clamp(0, width - 1);
          final int idx = py * yRowStride + px;
          final int luma = idx < yBytes.length ? yBytes[idx] : 128;
          sig8x8[gy * 8 + gx] = luma;
          totalLuma += luma;
        }
      }
      final double meanBrightness = totalLuma / 64.0;

      // Ước lượng độ sắc nét (phát hiện rung tay nhoè ảnh) bằng độ chênh lệch gradient lân cận
      double gradientSum = 0;
      int gradientCount = 0;
      for (int y = 16; y < height - 16; y += 24) {
        for (int x = 16; x < width - 16; x += 24) {
          final int idx = y * yRowStride + x;
          if (idx + 1 < yBytes.length) {
            gradientSum += (yBytes[idx + 1] - yBytes[idx]).abs();
            gradientCount++;
          }
        }
      }
      final double sharpnessScore =
          gradientCount > 0 ? gradientSum / gradientCount : 10.0;

      // 2. Chuyển YUV420 sang đối tượng img.Image (thư viện image)
      final img.Image rgbImage = _convertYuv420ToImage(cameraImage);

      // Xoay ảnh đúng chiều cầm dọc điện thoại Android (thường là 90 độ)
      img.Image oriented = rgbImage;
      if (sensorOrientation == 90) {
        oriented = img.copyRotate(rgbImage, angle: 90);
      } else if (sensorOrientation == 270) {
        oriented = img.copyRotate(rgbImage, angle: 270);
      } else if (sensorOrientation == 180) {
        oriented = img.copyRotate(rgbImage, angle: 180);
      }

      // 3. Resize cạnh dài về ~640px
      img.Image resized = oriented;
      final int maxSide = math.max(oriented.width, oriented.height);
      if (maxSide > AppConfig.targetMaxDimensionPx) {
        if (oriented.width >= oriented.height) {
          resized = img.copyResize(
            oriented,
            width: AppConfig.targetMaxDimensionPx,
          );
        } else {
          resized = img.copyResize(
            oriented,
            height: AppConfig.targetMaxDimensionPx,
          );
        }
      }

      // 4. Nén JPEG chất lượng 65 trong bộ nhớ RAM
      final Uint8List jpegBytes = Uint8List.fromList(
        img.encodeJpg(resized, quality: AppConfig.jpegQuality),
      );

      return SampledFrame(
        jpegBytes: jpegBytes,
        signature8x8: sig8x8,
        meanBrightness: meanBrightness,
        sharpnessScore: sharpnessScore,
        timestamp: DateTime.now(),
      );
    } catch (e) {
      debugPrint('Lỗi xử lý khung hình: $e');
      return null;
    }
  }

  /// So sánh độ khác biệt trung bình giữa 2 chữ ký 8x8 (0..255)
  static double computeSignatureDifference(List<int>? sigA, List<int>? sigB) {
    if (sigA == null || sigB == null || sigA.length != 64 || sigB.length != 64) {
      return 999.0; // Khung đầu tiên luôn coi là cảnh mới
    }
    double diffSum = 0;
    for (int i = 0; i < 64; i++) {
      diffSum += (sigA[i] - sigB[i]).abs();
    }
    return diffSum / 64.0;
  }

  static img.Image _convertYuv420ToImage(CameraImage cameraImage) {
    final int width = cameraImage.width;
    final int height = cameraImage.height;

    // Bước nhảy giảm nửa độ phân giải ngay khi chuyển YUV -> RGB nếu ảnh gốc lớn
    final int step = (math.max(width, height) > 1280) ? 2 : 1;
    final int outW = width ~/ step;
    final int outH = height ~/ step;

    final img.Image image = img.Image(width: outW, height: outH);

    final Plane yPlane = cameraImage.planes[0];
    final Plane uPlane =
        cameraImage.planes.length > 1 ? cameraImage.planes[1] : yPlane;
    final Plane vPlane =
        cameraImage.planes.length > 2 ? cameraImage.planes[2] : yPlane;

    final int yRowStride = yPlane.bytesPerRow;
    final int uvRowStride = uPlane.bytesPerRow;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

    for (int y = 0; y < outH; y++) {
      final int srcY = y * step;
      for (int x = 0; x < outW; x++) {
        final int srcX = x * step;
        final int yIndex = srcY * yRowStride + srcX;
        final int uvIndex =
            (srcY ~/ 2) * uvRowStride + (srcX ~/ 2) * uvPixelStride;

        final int yp =
            yIndex < yPlane.bytes.length ? yPlane.bytes[yIndex] : 0;
        final int up =
            uvIndex < uPlane.bytes.length ? uPlane.bytes[uvIndex] : 128;
        final int vp =
            uvIndex < vPlane.bytes.length ? vPlane.bytes[uvIndex] : 128;

        int r = (yp + 1.402 * (vp - 128)).round().clamp(0, 255);
        int g = (yp - 0.344136 * (up - 128) - 0.714136 * (vp - 128))
            .round()
            .clamp(0, 255);
        int b = (yp + 1.772 * (up - 128)).round().clamp(0, 255);

        image.setPixelRgb(x, y, r, g, b);
      }
    }
    return image;
  }
}

// ============================================================================
// 4. HÀM MAIN KHỞI ĐỘNG ỨNG DỤNG
// ============================================================================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    debugPrint('Chưa có file .env hoặc đang dùng --dart-define');
  }

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  runApp(const EyeHelperApp());
}

class EyeHelperApp extends StatelessWidget {
  const EyeHelperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.yellowAccent,
          onPrimary: Colors.black,
          surface: Colors.black,
          onSurface: Colors.yellowAccent,
        ),
      ),
      home: const EyeHelperLiveScreen(),
    );
  }
}

// ============================================================================
// 5. MÀN HÌNH CHÍNH DUY NHẤT: CAMERA LIVE + GROQ VISION + WHISPER + ML KIT OCR
// ============================================================================
class EyeHelperLiveScreen extends StatefulWidget {
  const EyeHelperLiveScreen({super.key});

  @override
  State<EyeHelperLiveScreen> createState() => _EyeHelperLiveScreenState();
}

class _EyeHelperLiveScreenState extends State<EyeHelperLiveScreen>
    with WidgetsBindingObserver {
  // --- Camera & Hàng đợi khung hình (chỉ giữ 1 khung mới nhất) ---
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isStreaming = false;
  SampledFrame? _latestSampledFrame;
  List<int>? _lastSentSignature8x8;
  DateTime? _lastSampleTimestamp;
  Timer? _liveSchedulerTimer;
  int _sampledFrameCount = 0;
  bool _hasAnnouncedMissingKey = false;

  // --- Trạng thái gửi Groq API & Rate Limit ---
  bool _isRequestInFlight = false;
  final List<DateTime> _requestTimestamps = [];
  DateTime? _cooldownUntil; // Khi gặp lỗi 429 thì tự giãn khoảng cách
  int _consecutive429Count = 0;

  // --- Cài đặt người dùng điều khiển bằng giọng nói / cử chỉ ---
  bool _isLiveActive = true;
  bool _isFastMode = true; // true = Nhanh (1.5s), false = Tiết kiệm (4.0s)
  bool _isDetailedMode = false; // true = Chi tiết hơn, false = Ngắn gọn 1-2 câu
  bool _showTextHistory = true; // Bật/tắt hiển thị lịch sử văn bản trên màn hình

  // --- TTS On-Device (vi-VN) & Chống đọc lặp ---
  final FlutterTts _tts = FlutterTts();
  bool _isSpeaking = false;
  double _speechRate = 0.52;
  String _lastSpokenText = '';
  DateTime? _lastSpokenTime;
  String _statusSubtitle = 'Đang khởi động EyeHelper...';

  // --- Ghi âm hỏi đáp Groq Whisper & Speech-to-Text On-Device dự phòng ---
  final AudioRecorder _audioRecorder = AudioRecorder();
  final stt.SpeechToText _onDeviceStt = stt.SpeechToText();
  bool _isRecordingVoice = false;

  // --- Đọc chữ Offline dự phòng (Google ML Kit Text Recognition) ---
  final TextRecognizer _mlKitTextRecognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  // --- Theo dõi Pin (Cảnh báo pin yếu) ---
  final Battery _battery = Battery();
  Timer? _batteryCheckTimer;
  bool _hasWarnedLowBattery = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeSystem();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _liveSchedulerTimer?.cancel();
    _batteryCheckTimer?.cancel();
    _stopCameraStream();
    _cameraController?.dispose();
    _audioRecorder.dispose();
    _mlKitTextRecognizer.close();
    _tts.stop();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stopCameraStream();
      controller.dispose();
      WakelockPlus.disable();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
      if (_isLiveActive) {
        WakelockPlus.enable();
      }
    }
  }

  // --------------------------------------------------------------------------
  // KHỞI TẠO TOÀN BỘ HỆ THỐNG
  // --------------------------------------------------------------------------
  Future<void> _initializeSystem() async {
    await _initTts();
    await _vibratePattern([0, 70]);
    await WakelockPlus.enable();

    final camPerm = await Permission.camera.request();
    await Permission.microphone.request();

    if (!camPerm.isGranted) {
      await _speak(
        'Vui lòng cấp quyền Camera trong cài đặt để EyeHelper nhìn giúp bạn.',
        urgent: true,
      );
      return;
    }

    await _initCamera();
    _startLiveEvaluationLoop();
    _startBatteryMonitor();

    const welcomeMsg =
        'EyeHelper đã sẵn sàng. Hình ảnh chỉ xử lý tạm thời để gửi AI mô tả và không lưu lại. '
        'Lưu ý: ứng dụng chỉ hỗ trợ, không thay thế gậy hoặc chó dẫn đường. '
        'Chạm một lần để tạm dừng hoặc tiếp tục. Chạm hai lần để nghe lại. '
        'Chạm giữ màn hình để nói câu hỏi hoặc ra lệnh.';
    await _speak(welcomeMsg, urgent: true, saveToHistory: false);
  }

  // --------------------------------------------------------------------------
  // TTS TIẾNG VIỆT & CHỐNG ĐỌC LẶP + NGẮT ƯU TIÊN CẢNH BÁO NGUY HIỂM
  // --------------------------------------------------------------------------
  Future<void> _initTts() async {
    await _tts.setLanguage('vi-VN');
    await _tts.setSpeechRate(_speechRate);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);

    _tts.setStartHandler(() {
      if (mounted) setState(() => _isSpeaking = true);
    });
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _isSpeaking = false);
    });
    _tts.setCancelHandler(() {
      if (mounted) setState(() => _isSpeaking = false);
    });
    _tts.setErrorHandler((_) {
      if (mounted) setState(() => _isSpeaking = false);
    });
  }

  bool _isHazardMessage(String text) {
    final lower = text.toLowerCase();
    return AppConfig.hazardKeywords.any((kw) => lower.contains(kw));
  }

  /// So sánh câu mới với câu vừa nói để chống đọc lặp
  bool _isDuplicateSpeech(String newText) {
    if (_lastSpokenText.isEmpty) return false;
    final a = _normalizeVi(newText);
    final b = _normalizeVi(_lastSpokenText);
    if (a == b) return true;

    // Nếu câu mới chứa >80% từ giống hệt câu vừa nói trong vòng 12 giây qua
    if (_lastSpokenTime != null &&
        DateTime.now().difference(_lastSpokenTime!).inSeconds < 12) {
      final wordsA = a.split(' ').where((w) => w.length > 1).toSet();
      final wordsB = b.split(' ').where((w) => w.length > 1).toSet();
      if (wordsA.isNotEmpty && wordsB.isNotEmpty) {
        final intersection = wordsA.intersection(wordsB).length;
        final similarity =
            intersection / math.max(wordsA.length, wordsB.length);
        if (similarity >= 0.78) return true;
      }
    }
    return false;
  }

  String _normalizeVi(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Future<void> _speak(
    String text, {
    bool urgent = false,
    bool saveToHistory = true,
    bool checkDuplicate = false,
  }) async {
    final cleaned = text.trim();
    if (cleaned.isEmpty || cleaned.contains('[IM_LANG]')) return;

    final isHazard = _isHazardMessage(cleaned);
    final shouldInterrupt = urgent || isHazard;

    if (checkDuplicate && !isHazard && _isDuplicateSpeech(cleaned)) {
      return;
    }

    if (!shouldInterrupt && _isSpeaking) {
      return;
    }

    if (isHazard) {
      // Rung cảnh báo kép mạnh khi phát hiện nguy hiểm
      await _vibratePattern([0, 180, 90, 220]);
    }

    if (shouldInterrupt && _isSpeaking) {
      await _tts.stop();
    }

    if (saveToHistory) {
      _lastSpokenText = cleaned;
      _lastSpokenTime = DateTime.now();
    }
    _updateSubtitle(cleaned);

    SemanticsService.announce(cleaned, TextDirection.ltr);
    await _tts.speak(cleaned);
  }

  // --------------------------------------------------------------------------
  // CAMERA STREAM & LẤY MẪU KHUNG HÌNH (CHỈ GIỮ KHUNG MỚI NHẤT)
  // --------------------------------------------------------------------------
  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        await _speak('Không tìm thấy camera trên máy.', urgent: true);
        return;
      }

      final backCam = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        backCam,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await controller.initialize();
      await controller.setFlashMode(FlashMode.off);

      if (!mounted) return;
      setState(() {
        _cameraController = controller;
        _isCameraInitialized = true;
      });

      await _startCameraStream();
    } catch (e) {
      await _speak('Không thể mở camera.', urgent: true);
    }
  }

  Future<void> _startCameraStream() async {
    final controller = _cameraController;
    if (controller == null ||
        !controller.value.isInitialized ||
        _isStreaming) {
      return;
    }
    await controller.startImageStream(_onCameraImage);
    if (mounted) setState(() => _isStreaming = true);
  }

  Future<void> _stopCameraStream() async {
    final controller = _cameraController;
    if (controller == null || !_isStreaming) return;
    try {
      await controller.stopImageStream();
    } catch (_) {}
    if (mounted) setState(() => _isStreaming = false);
  }

  void _onCameraImage(CameraImage cameraImage) {
    if (!_isLiveActive || _isRecordingVoice) return;

    final now = DateTime.now();
    final sampleIntervalMs = _isFastMode ? 1400 : 3500;
    if (_lastSampleTimestamp != null &&
        now.difference(_lastSampleTimestamp!).inMilliseconds <
            sampleIntervalMs) {
      return;
    }
    _lastSampleTimestamp = now;

    final sensorOrientation =
        _cameraController?.description.sensorOrientation ?? 90;
    final sampled = FrameProcessor.processCameraImage(
      cameraImage,
      sensorOrientation: sensorOrientation,
    );

    if (sampled != null) {
      // Hàng đợi chỉ giữ đúng 1 khung mới nhất, ghi đè khung cũ ngay trong RAM
      _latestSampledFrame = sampled;
      _sampledFrameCount++;
      if (mounted) setState(() {});
    }
  }

  // --------------------------------------------------------------------------
  // VÒNG LẶP ĐÁNH GIÁ & GỬI KHUNG HÌNH LÊN GROQ VISION (MỤC 2, 3, 4, 6)
  // --------------------------------------------------------------------------
  void _startLiveEvaluationLoop() {
    _liveSchedulerTimer?.cancel();
    _liveSchedulerTimer = Timer.periodic(
      const Duration(milliseconds: 800),
      (_) => _evaluateAndSendLiveFrame(),
    );
  }

  Future<void> _evaluateAndSendLiveFrame() async {
    if (!_isLiveActive ||
        _isRequestInFlight ||
        _isSpeaking ||
        _isRecordingVoice) {
      return;
    }

    final frame = _latestSampledFrame;
    if (frame == null) return;

    final now = DateTime.now();

    // 1. Kiểm tra thời gian chờ (cooldown) khi bị 429 hoặc theo chế độ Nhanh/Tiết kiệm
    if (_cooldownUntil != null && now.isBefore(_cooldownUntil!)) {
      return;
    }

    final minGapMs = _isFastMode ? 1600 : 4000;
    if (_requestTimestamps.isNotEmpty &&
        now.difference(_requestTimestamps.last).inMilliseconds < minGapMs) {
      return;
    }

    // 2. Kiểm tra thiếu sáng hoặc rung tay mạnh trước khi tốn token gửi API
    if (frame.meanBrightness < 22.0) {
      await _speak(
        'Trời hoặc phòng đang quá tối, camera không nhìn rõ.',
        checkDuplicate: true,
      );
      return;
    }
    if (frame.sharpnessScore < 1.8) {
      // Ảnh quá nhoè do rung tay mạnh -> đợi khung kế tiếp rõ hơn
      return;
    }

    // 3. Kiểm tra cảnh có thay đổi đáng kể so với khung đã gửi gần nhất không
    final diff = FrameProcessor.computeSignatureDifference(
      frame.signature8x8,
      _lastSentSignature8x8,
    );
    if (diff < AppConfig.sceneChangeThreshold) {
      return; // Cảnh ổn định -> im lặng, không gửi request
    }

    // 4. Kiểm tra giới hạn N request / phút (sliding window 60 giây)
    _requestTimestamps.removeWhere(
      (t) => now.difference(t).inSeconds >= 60,
    );
    if (_requestTimestamps.length >= AppConfig.maxRequestsPerMinute) {
      return;
    }

    // 5. Đủ điều kiện -> Gửi khung hình mới nhất lên Groq Vision
    _lastSentSignature8x8 = frame.signature8x8;
    await _sendFrameToGroqVision(frame);
  }

  Future<void> _sendFrameToGroqVision(
    SampledFrame frame, {
    String? userQuestion,
  }) async {
    final apiKey = AppConfig.groqApiKey;
    if (apiKey.isEmpty || apiKey.startsWith('gsk_dien_api_key')) {
      if (!_hasAnnouncedMissingKey) {
        _hasAnnouncedMissingKey = true;
        await _speak(
          'Chưa điền khóa Groq API trong file .env. Đang tự động dùng chế độ đọc chữ ngoại tuyến ML Kit.',
          urgent: false,
          saveToHistory: false,
        );
      } else if (userQuestion != null) {
        await _speak(
          'Chưa cấu hình khóa Groq API. Đang đọc chữ ngoại tuyến.',
          urgent: true,
        );
      }
      await _runOfflineOcrOnCurrentFrame(
        frame,
        forceAnnounceEmpty: userQuestion != null,
      );
      return;
    }

    _isRequestInFlight = true;
    _requestTimestamps.add(DateTime.now());

    try {
      final styleNote = _isDetailedMode
          ? 'Người dùng đang chọn chế độ chi tiết hơn (2-3 câu rõ ràng).'
          : 'Trả lời cực kỳ ngắn gọn 1-2 câu, thông tin quan trọng nói trước.';

      final userPrompt = (userQuestion != null && userQuestion.isNotEmpty)
          ? 'Câu hỏi của người khiếm thị: "$userQuestion". $styleNote'
          : 'Câu nói gần nhất của bạn là: "${_lastSpokenText.isEmpty ? "Chưa có" : _lastSpokenText}". '
              'Hãy quan sát khung hình hiện tại. Nếu có nguy hiểm/vật cản/bậc thang/xe cộ thì cảnh báo ngay đầu câu kèm số bước chân. '
              'Nếu cảnh không đổi so với câu gần nhất thì trả về đúng [IM_LANG]. $styleNote';

      final payload = {
        'model': AppConfig.visionModel,
        'temperature': 0.2,
        'max_tokens': _isDetailedMode ? 180 : 110,
        'messages': [
          {
            'role': 'system',
            'content': AppConfig.systemPrompt,
          },
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': userPrompt},
              {
                'type': 'image_url',
                'image_url': {
                  'url': frame.toDataUrl(),
                },
              },
            ],
          },
        ],
      };

      final response = await http
          .post(
            Uri.parse(AppConfig.groqChatEndpoint),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        _consecutive429Count = 0;
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final content =
            data['choices']?[0]?['message']?['content']?.toString().trim() ??
                '';

        if (content.isNotEmpty && !content.contains('[IM_LANG]')) {
          await _speak(
            content,
            urgent: userQuestion != null || _isHazardMessage(content),
            checkDuplicate: userQuestion == null,
          );
        }
      } else if (response.statusCode == 429) {
        // Tự động giãn khoảng cách khi vượt giới hạn Rate Limit 429
        _consecutive429Count++;
        final backoffSeconds = math.min(30, 5 * _consecutive429Count);
        _cooldownUntil = DateTime.now().add(Duration(seconds: backoffSeconds));
        await _speak(
          'Hệ thống đang bận, tự động chậm lại vài giây rồi tiếp tục.',
          urgent: false,
          saveToHistory: false,
        );
      } else {
        debugPrint('Groq Vision HTTP ${response.statusCode}: ${response.body}');
        if (userQuestion != null) {
          await _speak(
            'Kết nối AI gặp sự cố, đang thử đọc chữ ngoại tuyến.',
            urgent: true,
          );
          await _runOfflineOcrOnCurrentFrame(frame);
        }
      }
    } on SocketException {
      await _vibratePattern([0, 100, 80, 100]);
      await _speak(
        'Mất kết nối mạng. Đang chuyển sang chế độ đọc chữ ngoại tuyến.',
        urgent: false,
        checkDuplicate: true,
      );
      await _runOfflineOcrOnCurrentFrame(frame);
    } on TimeoutException {
      if (userQuestion != null) {
        await _speak('Mạng phản hồi chậm, vui lòng hỏi lại.', urgent: true);
      }
    } catch (e) {
      debugPrint('Lỗi gọi Groq Vision: $e');
    } finally {
      _isRequestInFlight = false;
    }
  }

  // --------------------------------------------------------------------------
  // BƯỚC 3: THU ÂM HỎI ĐÁP GROQ WHISPER + FALLBACK SPEECH_TO_TEXT + LỆNH GIỌNG NÓI
  // --------------------------------------------------------------------------
  Future<void> _handleLongPressStart(LongPressStartDetails details) async {
    await _vibratePattern([0, 120]);
    if (_isSpeaking) {
      await _tts.stop();
    }

    final micPerm = await Permission.microphone.request();
    if (!micPerm.isGranted) {
      await _speak('Chưa có quyền micro để nghe câu hỏi.', urgent: true);
      return;
    }

    try {
      final tempDir = await getTemporaryDirectory();
      final audioPath = '${tempDir.path}/eye_helper_query.m4a';
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 16000,
        ),
        path: audioPath,
      );
      setState(() => _isRecordingVoice = true);
      _updateSubtitle('Đang nghe... Hãy nói câu hỏi hoặc lệnh rồi thả tay.');
    } catch (e) {
      debugPrint('Lỗi bắt đầu ghi âm: $e');
    }
  }

  Future<void> _handleLongPressEnd(LongPressEndDetails details) async {
    if (!_isRecordingVoice) return;
    await _vibratePattern([0, 70]);
    setState(() => _isRecordingVoice = false);

    String? recordedPath;
    try {
      recordedPath = await _audioRecorder.stop();
    } catch (_) {}

    if (recordedPath == null || recordedPath.isEmpty) {
      await _speak('Không thu được âm thanh.', urgent: true);
      return;
    }

    final audioFile = File(recordedPath);
    String recognizedText = await _transcribeWithGroqWhisper(audioFile);

    // Xóa ngay file ghi âm tạm sau khi gửi để đảm bảo quyền riêng tư
    try {
      if (await audioFile.exists()) {
        await audioFile.delete();
      }
    } catch (_) {}

    // Nếu Groq Whisper lỗi/mất mạng -> fallback sang speech_to_text on-device
    if (recognizedText.isEmpty) {
      recognizedText = await _fallbackOnDeviceSpeechToText();
    }

    if (recognizedText.trim().isEmpty) {
      await _speak('Tôi chưa nghe rõ, bạn hãy chạm giữ và nói lại nhé.',
          urgent: true, saveToHistory: false);
      return;
    }

    _updateSubtitle('Bạn nói: "$recognizedText"');
    await _processUserVoiceInput(recognizedText.trim());
  }

  Future<String> _transcribeWithGroqWhisper(File audioFile) async {
    final apiKey = AppConfig.groqApiKey;
    if (apiKey.isEmpty || !await audioFile.exists()) return '';

    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse(AppConfig.groqAudioEndpoint),
      );
      request.headers['Authorization'] = 'Bearer $apiKey';
      request.fields['model'] = AppConfig.defaultWhisperModel;
      request.fields['language'] = 'vi';
      request.fields['response_format'] = 'json';
      request.files.add(
        await http.MultipartFile.fromPath('file', audioFile.path),
      );

      final streamed =
          await request.send().timeout(const Duration(seconds: 10));
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        return data['text']?.toString().trim() ?? '';
      }
    } catch (e) {
      debugPrint('Groq Whisper lỗi, chuyển sang STT on-device: $e');
    }
    return '';
  }

  Future<String> _fallbackOnDeviceSpeechToText() async {
    try {
      final available = await _onDeviceStt.initialize();
      if (!available) return '';

      final completer = Completer<String>();
      await _onDeviceStt.listen(
        localeId: 'vi_VN',
        listenFor: const Duration(seconds: 4),
        onResult: (result) {
          if (result.finalResult && !completer.isCompleted) {
            completer.complete(result.recognizedWords);
          }
        },
      );

      return await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _onDeviceStt.stop();
          return '';
        },
      );
    } catch (_) {
      return '';
    }
  }

  /// Xử lý lệnh giọng nói cục bộ hoặc gửi câu hỏi kèm khung hình hiện tại lên Groq
  Future<void> _processUserVoiceInput(String text) async {
    final lower = text.toLowerCase();

    if (lower == 'dừng' ||
        lower.contains('tạm dừng') ||
        lower.contains('dừng lại')) {
      setState(() => _isLiveActive = false);
      await _speak('Đã tạm dừng nhìn trực tiếp.',
          urgent: true, saveToHistory: false);
      return;
    }

    if (lower.contains('tiếp tục')) {
      setState(() => _isLiveActive = true);
      await _speak('Đã tiếp tục nhìn trực tiếp.',
          urgent: true, saveToHistory: false);
      return;
    }

    if (lower.contains('nói chậm lại') || lower.contains('chậm lại')) {
      _speechRate = (_speechRate - 0.10).clamp(0.30, 0.90);
      await _tts.setSpeechRate(_speechRate);
      await _speak('Đã giảm tốc độ đọc chậm lại.',
          urgent: true, saveToHistory: false);
      return;
    }

    if (lower.contains('nói nhanh hơn') || lower.contains('nhanh lên')) {
      _speechRate = (_speechRate + 0.10).clamp(0.30, 0.90);
      await _tts.setSpeechRate(_speechRate);
      await _speak('Đã tăng tốc độ đọc nhanh hơn.',
          urgent: true, saveToHistory: false);
      return;
    }

    if (lower.contains('chi tiết hơn') || lower.contains('đọc hết đi')) {
      setState(() => _isDetailedMode = true);
      final frame = _latestSampledFrame;
      if (frame != null) {
        await _sendFrameToGroqVision(
          frame,
          userQuestion:
              'Hãy mô tả thật chi tiết mọi thứ và đọc toàn bộ chữ nhìn thấy trong ảnh.',
        );
      } else {
        await _speak('Đã bật chế độ mô tả chi tiết hơn.',
            urgent: true, saveToHistory: false);
      }
      return;
    }

    if (lower.contains('ngắn gọn thôi') || lower.contains('ngắn gọn')) {
      setState(() => _isDetailedMode = false);
      await _speak('Đã chuyển về chế độ mô tả ngắn gọn một đến hai câu.',
          urgent: true, saveToHistory: false);
      return;
    }

    if (lower.contains('tiết kiệm')) {
      setState(() => _isFastMode = false);
      await _speak('Đã chuyển sang chế độ quét tiết kiệm, bốn giây một khung.',
          urgent: true, saveToHistory: false);
      return;
    }

    if (lower.contains('quét nhanh') || lower == 'nhanh') {
      setState(() => _isFastMode = true);
      await _speak('Đã chuyển sang chế độ quét nhanh.',
          urgent: true, saveToHistory: false);
      return;
    }

    if (lower.contains('tắt lịch sử') || lower.contains('ẩn chữ')) {
      setState(() => _showTextHistory = false);
      await _speak('Đã ẩn lịch sử văn bản trên màn hình.',
          urgent: true, saveToHistory: false);
      return;
    }

    if (lower.contains('bật lịch sử') || lower.contains('hiện chữ')) {
      setState(() => _showTextHistory = true);
      await _speak('Đã hiện lịch sử văn bản trên màn hình.',
          urgent: true, saveToHistory: false);
      return;
    }

    if (lower == 'đọc chữ' || lower.contains('đọc chữ ngoại tuyến')) {
      final frame = _latestSampledFrame;
      if (frame != null) {
        await _runOfflineOcrOnCurrentFrame(frame, forceAnnounceEmpty: true);
      }
      return;
    }

    // Còn lại là câu hỏi trực tiếp của người dùng ("Cái bên trái là gì?", "Bao nhiêu tiền?"...)
    final frame = _latestSampledFrame;
    if (frame == null) {
      await _speak('Camera chưa sẵn sàng khung hình, bạn hãy thử lại.',
          urgent: true);
      return;
    }
    await _sendFrameToGroqVision(frame, userQuestion: text);
  }

  // --------------------------------------------------------------------------
  // BƯỚC 5: ĐỌC CHỮ OFFLINE DỰ PHÒNG BẰNG GOOGLE ML KIT TEXT RECOGNITION
  // --------------------------------------------------------------------------
  Future<void> _runOfflineOcrOnCurrentFrame(
    SampledFrame frame, {
    bool forceAnnounceEmpty = false,
  }) async {
    File? tempFile;
    try {
      final dir = await getTemporaryDirectory();
      tempFile = File('${dir.path}/ocr_temp_frame.jpg');
      await tempFile.writeAsBytes(frame.jpegBytes, flush: true);

      final inputImage = InputImage.fromFilePath(tempFile.path);
      final RecognizedText recognizedText =
          await _mlKitTextRecognizer.processImage(inputImage);

      final text = recognizedText.text.replaceAll('\n', ', ').trim();
      if (text.isNotEmpty) {
        await _speak('Chữ đọc được: $text', urgent: true);
      } else if (forceAnnounceEmpty) {
        await _speak('Không tìm thấy chữ rõ ràng trước camera.',
            urgent: true, saveToHistory: false);
      }
    } catch (e) {
      debugPrint('Lỗi ML Kit OCR: $e');
    } finally {
      try {
        if (tempFile != null && await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {}
    }
  }

  // --------------------------------------------------------------------------
  // BƯỚC 7: THEO DÕI PIN YẾU & CỬ CHỈ CHẠM / VUỐT
  // --------------------------------------------------------------------------
  void _startBatteryMonitor() {
    _batteryCheckTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) async {
        try {
          final level = await _battery.batteryLevel;
          if (level <= 15 && !_hasWarnedLowBattery) {
            _hasWarnedLowBattery = true;
            setState(() => _isFastMode = false); // Tự chuyển sang tiết kiệm
            await _speak(
              'Cảnh báo: Pin điện thoại còn $level phần trăm. Đã tự động chuyển sang chế độ quét tiết kiệm.',
              urgent: true,
              saveToHistory: false,
            );
          }
        } catch (_) {}
      },
    );
  }

  Future<void> _handleSingleTap() async {
    await _vibratePattern([0, 60]);
    setState(() => _isLiveActive = !_isLiveActive);
    if (_isLiveActive) {
      await WakelockPlus.enable();
      await _speak('Đã tiếp tục nhìn trực tiếp.',
          urgent: true, saveToHistory: false);
    } else {
      await WakelockPlus.disable();
      await _speak('Đã tạm dừng.', urgent: true, saveToHistory: false);
    }
  }

  Future<void> _handleDoubleTap() async {
    await _vibratePattern([0, 90]);
    final msg = _lastSpokenText.isEmpty
        ? 'Chưa có câu thông báo nào trước đó.'
        : 'Nhắc lại: $_lastSpokenText';
    await _speak(msg, urgent: true, saveToHistory: false);
  }

  Future<void> _handleVerticalDragEnd(DragEndDetails details) async {
    final v = details.primaryVelocity ?? 0.0;
    if (v.abs() < 150) return;

    await _vibratePattern([0, 50]);
    if (v < 0) {
      _speechRate = (_speechRate + 0.08).clamp(0.30, 0.90);
      await _tts.setSpeechRate(_speechRate);
      await _speak('Đã tăng tốc độ đọc.', urgent: true, saveToHistory: false);
    } else {
      _speechRate = (_speechRate - 0.08).clamp(0.30, 0.90);
      await _tts.setSpeechRate(_speechRate);
      await _speak('Đã giảm tốc độ đọc.', urgent: true, saveToHistory: false);
    }
  }

  Future<void> _vibratePattern(List<int> pattern) async {
    try {
      if (await Vibration.hasVibrator() == true) {
        await Vibration.vibrate(pattern: pattern);
      } else {
        await HapticFeedback.mediumImpact();
      }
    } catch (_) {
      await HapticFeedback.mediumImpact();
    }
  }

  void _updateSubtitle(String text) {
    if (!mounted) return;
    setState(() => _statusSubtitle = text);
  }

  // --------------------------------------------------------------------------
  // GIAO DIỆN TOÀN MÀN HÌNH TƯƠNG PHẢN CAO (TALKBACK SEMANTICS TIẾNG VIỆT)
  // --------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Semantics(
          label:
              'Màn hình Camera trực tiếp EyeHelper. Trạng thái: ${_isLiveActive ? "Đang hoạt động" : "Đang tạm dừng"}. '
              'Chế độ quét: ${_isFastMode ? "Nhanh" : "Tiết kiệm"}. '
              'Chạm một lần để tạm dừng hoặc tiếp tục. '
              'Chạm hai lần để nghe lại câu vừa nói. '
              'Chạm giữ để hỏi bằng giọng nói. '
              'Vuốt lên hoặc xuống để chỉnh tốc độ giọng đọc.',
          hint: 'Vùng cảm ứng toàn màn hình hỗ trợ người khiếm thị',
          button: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _handleSingleTap,
            onDoubleTap: _handleDoubleTap,
            onLongPressStart: _handleLongPressStart,
            onLongPressEnd: _handleLongPressEnd,
            onVerticalDragEnd: _handleVerticalDragEnd,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_isCameraInitialized && _cameraController != null)
                  CameraPreview(_cameraController!)
                else
                  const Center(
                    child: CircularProgressIndicator(
                      color: Colors.yellowAccent,
                      strokeWidth: 4,
                    ),
                  ),
                Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      width: double.infinity,
                      color: Colors.black.withValues(alpha: 0.85),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _isRecordingVoice
                                ? Icons.mic
                                : (_isLiveActive
                                    ? Icons.visibility
                                    : Icons.pause_circle_filled),
                            color: _isRecordingVoice
                                ? Colors.redAccent
                                : (_isLiveActive
                                    ? Colors.greenAccent
                                    : Colors.orangeAccent),
                            size: 32,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _isRecordingVoice
                                  ? 'ĐANG NGHE CÂU HỎI...'
                                  : (_isLiveActive
                                      ? 'LIVE #$_sampledFrameCount (${_isFastMode ? "Nhanh 1.5s" : "Tiết kiệm 4s"})'
                                      : 'ĐANG TẠM DỪNG'),
                              style: const TextStyle(
                                color: Colors.yellowAccent,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_showTextHistory)
                      Container(
                        width: double.infinity,
                        color: Colors.black.withValues(alpha: 0.88),
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          _statusSubtitle,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            height: 1.35,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
