/// One downloadable GGUF model choice for the (Windows-only, optional)
/// local-AI question understanding layer - see local_llm_manager.dart.
///
/// [approxSizeBytes] is a rough label for the "download ~X Go ?" prompt
/// before starting, not something to rely on for progress - the real
/// download always tracks the HTTP response's actual Content-Length (see
/// model_downloader.dart), so a stale estimate here can never make the
/// progress bar wrong, only the up-front size hint. [sha256] is left null
/// deliberately rather than guessed: this was written from an environment
/// that couldn't reach Hugging Face to compute a real checksum (see
/// ROADMAP.md) - a wrong hardcoded hash would be worse than none, since it
/// would make every real download "fail verification". Whoever finishes
/// verifying this on a real Windows machine should fill it in from the
/// first successful download (sha256sum on the file) so future downloads
/// get real corruption detection.
class LocalLlmModel {
  final String id;
  final String label;
  final String description;
  final String downloadUrl;
  final String fileName;
  final int approxSizeBytes;
  final String? sha256;

  const LocalLlmModel({
    required this.id,
    required this.label,
    required this.description,
    required this.downloadUrl,
    required this.fileName,
    required this.approxSizeBytes,
    this.sha256,
  });
}

/// Two size options, smallest first - both Qwen2.5 Instruct, a model family
/// chosen for reliable instruction-following (staying on-format for a
/// JSON-only answer) at small sizes, quantized to Q4_K_M (a common
/// accuracy/size compromise for CPU inference without a dedicated GPU).
const List<LocalLlmModel> localLlmModels = [
  LocalLlmModel(
    id: 'qwen2.5-3b-instruct-q4_k_m',
    label: 'Qwen2.5 3B (rapide, ~2 Go)',
    description: 'Plus rapide et léger, suffisant pour des questions simples.',
    downloadUrl:
        'https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf?download=true',
    fileName: 'Qwen2.5-3B-Instruct-Q4_K_M.gguf',
    approxSizeBytes: 2 * 1024 * 1024 * 1024,
  ),
  LocalLlmModel(
    id: 'qwen2.5-7b-instruct-q4_k_m',
    label: 'Qwen2.5 7B (plus fiable, ~4,7 Go)',
    description: 'Plus lent à télécharger et à répondre, mais comprend mieux les questions formulées de façon inhabituelle.',
    downloadUrl:
        'https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf?download=true',
    fileName: 'Qwen2.5-7B-Instruct-Q4_K_M.gguf',
    approxSizeBytes: 4700 * 1024 * 1024,
  ),
];

LocalLlmModel? localLlmModelById(String id) {
  for (final model in localLlmModels) {
    if (model.id == id) return model;
  }
  return null;
}
