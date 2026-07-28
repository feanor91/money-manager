import 'package:flutter/material.dart';

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

  const SearchableSelectField({
    super.key,
    required this.label,
    required this.options,
    required this.labelOf,
    required this.onSelected,
    this.initialValue,
    this.onCreate,
  });

  @override
  State<SearchableSelectField<T>> createState() => _SearchableSelectFieldState<T>();
}

class _SearchableSelectFieldState<T extends Object> extends State<SearchableSelectField<T>> {
  late final TextEditingController _pendingTextHolder;

  @override
  void initState() {
    super.initState();
    _pendingTextHolder = TextEditingController();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Autocomplete<T>(
            initialValue: TextEditingValue(
              text: widget.initialValue != null ? widget.labelOf(widget.initialValue as T) : '',
            ),
            displayStringForOption: widget.labelOf,
            optionsBuilder: (textEditingValue) {
              _pendingTextHolder.text = textEditingValue.text;
              final query = textEditingValue.text.trim().toLowerCase();
              if (query.isEmpty) return widget.options;
              return widget.options.where((o) => widget.labelOf(o).toLowerCase().contains(query));
            },
            onSelected: widget.onSelected,
            fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
              return TextFormField(
                controller: controller,
                focusNode: focusNode,
                decoration: InputDecoration(
                  labelText: widget.label,
                  suffixIcon: controller.text.isEmpty
                      ? const Icon(Icons.search, size: 18)
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            controller.clear();
                            widget.onSelected(null);
                          },
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
                    constraints: const BoxConstraints(maxHeight: 320, minWidth: 240),
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: list.length,
                      itemBuilder: (context, index) {
                        final option = list[index];
                        return ListTile(
                          dense: true,
                          title: _OptionLabel(text: widget.labelOf(option)),
                          onTap: () => onSelectedCallback(option),
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
            tooltip: 'Creer un nouvel element',
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
          TextSpan(text: text.substring(0, separator + 1), style: TextStyle(color: muted)),
          TextSpan(
            text: text.substring(separator + 1),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
