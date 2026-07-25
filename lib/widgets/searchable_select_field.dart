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
                    constraints: const BoxConstraints(maxHeight: 240, minWidth: 240),
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: list.length,
                      itemBuilder: (context, index) {
                        final option = list[index];
                        return ListTile(
                          dense: true,
                          title: Text(widget.labelOf(option)),
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
