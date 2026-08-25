import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Same convention as transactions_screen.dart's _isAndroidPlatform/
/// voice_transaction_sheet.dart - gates [SearchableSelectField.enableVoiceInput]'s
/// mic button so it never renders (and speech_to_text's web/desktop
/// backends are never exercised) off Android.
bool get _isAndroidPlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// A text field that filters [options] as the user types (instead of a
/// plain dropdown you have to scroll through), built on Flutter's
/// [Autocomplete]. Optionally shows a "create" button that inserts a new
/// entry from the currently typed text (e.g. a new payee or category).
class SearchableSelectField<T extends Object> extends StatefulWidget {
  final String label;
  final List<T> options;
  final String Function(T) labelOf;
  final T? initialValue;
  final ValueChanged<T?> onSelected;
  final Future<T?> Function(String text)? onCreate;

  /// Fired on every keystroke with the raw typed text, separately from
  /// [onSelected] - lets a caller resolve/auto-create an entry at save
  /// time from whatever was last typed, even if the user never picked a
  /// match from the dropdown or tapped [onCreate]'s button explicitly
  /// (see TransactionEditorSheet/RecurringEditorSheet's "Tiers" field).
  final ValueChanged<String>? onTextChanged;

  /// Adds a microphone button (Android only - see [_isAndroidPlatform])
  /// that dictates into the search text, reusing the exact same
  /// type-to-filter path as typing does - the user still taps their
  /// intended match from the filtered list rather than a guess being
  /// auto-selected, same "a wrong guess costs a tap to fix" principle as
  /// [VoiceTransactionSheet]. Added 2026-08-06 for the Tiers field
  /// specifically (transactions_screen.dart/recurring_screen.dart) but
  /// left generic - opt-in per field via this flag rather than always-on,
  /// since not every use of this widget (e.g. Catégorie) was asked for.
  final bool enableVoiceInput;

  const SearchableSelectField({
    super.key,
    required this.label,
    required this.options,
    required this.labelOf,
    required this.onSelected,
    this.initialValue,
    this.onCreate,
    this.onTextChanged,
    this.enableVoiceInput = false,
  });

  @override
  State<SearchableSelectField<T>> createState() =>
      _SearchableSelectFieldState<T>();
}

class _SearchableSelectFieldState<T extends Object>
    extends State<SearchableSelectField<T>> {
  late final TextEditingController _pendingTextHolder;
  stt.SpeechToText? _speech;
  bool _listening = false;

  bool get _voiceAvailable => widget.enableVoiceInput && _isAndroidPlatform;

  @override
  void initState() {
    super.initState();
    _pendingTextHolder = TextEditingController();
  }

  @override
  void dispose() {
    // Belt-and-braces, same reasoning as VoiceTransactionSheet.dispose：
    // don't leave the recognizer running past the widget that owns its
    // callbacks if this field is torn down mid-listen.
    if (_listening) _speech?.cancel();
    super.dispose();
  }

  /// Dictates a short phrase directly into [controller] - Autocomplete
  /// already listens to that same controller for its type-to-filter
  /// behaviour, so setting its text here re-triggers the normal filtered
  /// dropdown exactly as if it had been typed. Deliberately
  /// [stt.ListenMode.search] and short pause/listen windows, not
  /// [VoiceTransactionSheet]'s dictation-length settings - a name is a
  /// couple of words, not a sentence.
  Future<void> _toggleListening(TextEditingController controller) async {
    if (_listening) {
      await _speech?.stop();
      return;
    }
    final speech = _speech ??= stt.SpeechToText();
    final available = await speech.initialize(
      onStatus: (status) {
        if (!mounted) return;
        if (status == 'notListening' || status == 'done') {
          setState(() => _listening = false);
        }
      },
    );
    if (!available || !mounted) return;
    setState(() => _listening = true);
    unawaited(speech.listen(
      onResult: (result) {
        controller.text = result.recognizedWords;
        controller.selection =
            TextSelection.collapsed(offset: controller.text.length);
      },
      listenOptions: stt.SpeechListenOptions(
        localeId: 'fr_FR',
        listenMode: stt.ListenMode.search,
        partialResults: true,
        pauseFor: const Duration(seconds: 2),
        listenFor: const Duration(seconds: 10),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Autocomplete<T>(
            initialValue: TextEditingValue(
              text: widget.initialValue != null
                  ? widget.labelOf(widget.initialValue as T)
                  : '',
            ),
            displayStringForOption: widget.labelOf,
            optionsBuilder: (textEditingValue) {
              _pendingTextHolder.text = textEditingValue.text;
              widget.onTextChanged?.call(textEditingValue.text);
              final query = textEditingValue.text.trim().toLowerCase();
              if (query.isEmpty) return widget.options;
              return widget.options.where(
                  (o) => widget.labelOf(o).toLowerCase().contains(query));
            },
            onSelected: widget.onSelected,
            fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
              return TextFormField(
                controller: controller,
                focusNode: focusNode,
                decoration: InputDecoration(
                  labelText: widget.label,
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_voiceAvailable)
                        IconButton(
                          tooltip: _listening ? 'Arrêter' : 'Dicter',
                          icon: Icon(
                            _listening ? Icons.mic : Icons.mic_none,
                            size: 18,
                            color: _listening
                                ? Theme.of(context).colorScheme.error
                                : null,
                          ),
                          onPressed: () => _toggleListening(controller),
                        ),
                      controller.text.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.only(right: 12),
                              child: Icon(Icons.search, size: 18),
                            )
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                controller.clear();
                                widget.onSelected(null);
                              },
                            ),
                    ],
                  ),
                ),
                onFieldSubmitted: (_) => onSubmitted(),
              );
            },
            optionsViewBuilder: (context, onSelectedCallback, opts) {
              final list = opts.toList();
              return Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(12),
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxHeight: 320, minWidth: 240),
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: list.length,
                      itemBuilder: (context, index) {
                        final option = list[index];
                        // A raw Listener.onPointerDown, not
                        // InkWell.onTap/onTapDown (2026-08-24, intermittent
                        // "can't select an option" report, most visibly a
                        // single filtered match on the ledger's transaction
                        // form). Root cause, confirmed with a widget test
                        // that reproduces it (see
                        // searchable_select_field_test.dart's "selection
                        // survives a rebuild landing between pointer-down
                        // and pointer-up"): this row sits inside a
                        // ListView, so its InkWell's TapGestureRecognizer
                        // shares a gesture arena with the ListView's own
                        // scroll/pan recognizer - the arena only resolves
                        // (and only THEN does onTapDown/onTap actually
                        // fire) once it's clear the pan recognizer won't
                        // claim the gesture, which is deferred all the way
                        // to pointer-up, not pointer-down as the name
                        // suggests. If a ChangeNotifier rebuild (this form
                        // watches DatabaseProvider, which fires for
                        // unrelated reasons - a debounced save completing,
                        // etc.) tears down and rebuilds this exact row
                        // before that resolution, the tap is silently
                        // dropped. Listener.onPointerDown bypasses the
                        // gesture arena entirely - it fires on the raw
                        // pointer-down event unconditionally, before any
                        // rebuild has a chance to interrupt it. The InkWell
                        // stays, purely for the visual tap ripple - it no
                        // longer drives the actual selection.
                        return Listener(
                          key: ValueKey(widget.labelOf(option)),
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: (_) => onSelectedCallback(option),
                          child: InkWell(
                            onTap: () {},
                            child: ListTile(
                              dense: true,
                              title: _OptionLabel(text: widget.labelOf(option)),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (widget.onCreate != null)
          IconButton(
            tooltip: 'Créer un nouvel élément',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () async {
              final text = _pendingTextHolder.text.trim();
              if (text.isEmpty) return;
              final created = await widget.onCreate!(text);
              if (created != null) widget.onSelected(created);
            },
          ),
      ],
    );
  }
}

/// Renders a "Parent:Child" option label (e.g. a category's full path) with
/// the parent segment muted and the leaf segment emphasized, so a long
/// alphabetical list still reads as grouped-by-parent at a glance instead
/// of a flat wall of text. Falls back to a plain label when there's no
/// ":" to split on (top-level categories, payee names, ...).
class _OptionLabel extends StatelessWidget {
  final String text;

  const _OptionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    final separator = text.lastIndexOf(':');
    if (separator == -1) {
      return Text(text, style: const TextStyle(fontWeight: FontWeight.w600));
    }
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return RichText(
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: DefaultTextStyle.of(context).style,
        children: [
          TextSpan(
              text: text.substring(0, separator + 1),
              style: TextStyle(color: muted)),
          TextSpan(
            text: text.substring(separator + 1),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
