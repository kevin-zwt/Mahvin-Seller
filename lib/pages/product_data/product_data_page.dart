import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../common/widgets/adaptive_grid.dart';
import '../../common/widgets/app_button.dart';
import '../../common/widgets/app_card.dart';
import '../../common/widgets/empty_state.dart';
import '../../common/widgets/section_header.dart';
import '../../core/download/file_downloader.dart';
import '../../core/download/image_downloader.dart';
import '../../core/files/template_picker.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/meesho_template_service.dart';
import '../../data/models/product_link_data.dart';
import '../../data/product_link_service.dart';
import '../../data/seo_service.dart';

typedef TemplatePicker = Future<PickedTemplateFile?> Function();
typedef TemplateSaver = Future<bool> Function(Uint8List bytes, String fileName);

/// Reads a pasted e-commerce product link and shows listing-ready details.
class ProductDataPage extends StatefulWidget {
  const ProductDataPage({
    super.key,
    required this.source,
    this.templatePicker,
    this.templateSaver,
    this.templateService = const MeeshoTemplateService(),
    this.seoService,
  });

  /// Writes the SEO title and description; created from local preferences
  /// when not given.
  final SeoService? seoService;
  final ProductLinkSource source;
  final TemplatePicker? templatePicker;
  final TemplateSaver? templateSaver;
  final MeeshoTemplateService templateService;

  @override
  State<ProductDataPage> createState() => _ProductDataPageState();
}

class _ProductDataPageState extends State<ProductDataPage> {
  final TextEditingController _linkController = TextEditingController();

  bool _loading = false;
  String? _error;
  ProductLinkData? _data;
  int _requestId = 0;

  MeeshoTemplate? _template;
  Map<int, String> _templateEdits = {};
  bool _showTemplateErrors = false;
  bool _templateLoading = false;
  bool _templateSaving = false;
  String? _templateError;

  SeoService? _seo;

  @override
  void initState() {
    super.initState();
    _seo = widget.seoService;
    if (_seo == null) {
      SharedPreferences.getInstance()
          .then((prefs) {
            if (mounted) setState(() => _seo = SeoService(prefs: prefs));
          })
          .catchError((_) {});
    }
  }

  /// Writes SEO text for one template field (its title or description) with
  /// Groq. [current] is what the field holds now; a regenerate asks for
  /// something different. Returns null when nothing was written.
  Future<String?> _generateSeo(
    MeeshoTemplateColumn column,
    String current,
  ) async {
    final seo = _seo;
    final data = _data;
    if (seo == null || data == null) return null;
    if (!seo.isConfigured) {
      final saved = await showDialog<bool>(
        context: context,
        builder: (_) => _GroqKeyDialog(service: seo),
      );
      if (saved != true || !mounted || !seo.isConfigured) return null;
    }
    final part = column.fieldKey == 'title'
        ? SeoPart.title
        : SeoPart.description;
    final service = widget.templateService;
    String clean(String text) => service.cleanText(data, text);
    try {
      final content = await seo.generate(
        SeoInput(
          title: clean(data.title),
          description: clean(data.description),
          features: clean(data.keyFeatures.join('\n')),
          specs: clean(
            data.specs.map((spec) => '${spec.label}: ${spec.value}').join('\n'),
          ),
          category: data.category,
        ),
        part: part,
        previous: current,
        scrub: clean,
      );
      return part == SeoPart.title ? content.title : content.description;
    } on SeoException catch (error) {
      if (mounted) _showMessage(error.message);
    } catch (_) {
      if (mounted) _showMessage('Could not write the SEO text. Try again.');
    }
    return null;
  }

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  Future<void> _fetch({String? raw}) async {
    if (_loading) return;
    final value = (raw ?? _linkController.text).trim();
    if (value.isEmpty) {
      _showMessage('Paste a product link first.');
      return;
    }
    FocusScope.of(context).unfocus();
    _linkController.text = value;

    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
      _data = null;
      _template = null;
      _templateEdits = {};
      _showTemplateErrors = false;
      _templateError = null;
      _templateLoading = false;
      _templateSaving = false;
    });

    try {
      final data = await widget.source.load(value);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } on ProductLinkException catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error =
            'Could not read that product page. Check the link and your '
            'connection, then try again.';
        _loading = false;
      });
    }
  }

  void _clear() {
    _requestId++;
    _linkController.clear();
    setState(() {
      _data = null;
      _error = null;
      _loading = false;
      _template = null;
      _templateEdits = {};
      _showTemplateErrors = false;
      _templateError = null;
      _templateLoading = false;
      _templateSaving = false;
    });
  }

  Future<void> _paste() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboard?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      _showMessage('Your clipboard does not contain a link.');
      return;
    }
    _linkController.text = text;
    _showMessage('Link pasted. Tap Fetch product data.');
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        _showMessage('Could not open that link.');
      }
    } catch (_) {
      if (mounted) _showMessage('Could not open that link.');
    }
  }

  Future<void> _downloadPhoto(ProductLinkData data, int index) async {
    final photo = data.photos[index];
    final fileName = _photoFileName(data.title, index, photo.url);
    final saved = await downloadImage(photo.url, fileName);
    if (!mounted) return;
    if (saved) {
      _showMessage('Photo ${index + 1} downloaded.');
    } else {
      await _openLink(photo.url);
      if (mounted) {
        _showMessage('Download is unavailable here. Opened the photo instead.');
      }
    }
  }

  Future<void> _downloadAll(ProductLinkData data) async {
    if (data.photos.isEmpty) return;
    var saved = 0;
    for (var i = 0; i < data.photos.length; i++) {
      final fileName = _photoFileName(data.title, i, data.photos[i].url);
      if (await downloadImage(data.photos[i].url, fileName)) saved++;
    }
    if (!mounted) return;
    if (saved == 0) {
      await _openLink(data.photos.first.url);
      if (mounted) {
        _showMessage('Download is unavailable here. Opened the first photo.');
      }
      return;
    }
    _showMessage('$saved photo${saved == 1 ? '' : 's'} downloaded.');
  }

  Future<void> _chooseTemplate() async {
    final data = _data;
    if (data == null || _templateLoading || _templateSaving) return;
    setState(() {
      _templateLoading = true;
      _templateError = null;
    });
    try {
      final picked = await (widget.templatePicker ?? pickExcelTemplate)();
      if (!mounted) return;
      if (picked == null) {
        setState(() => _templateLoading = false);
        return;
      }
      final template = widget.templateService.analyze(
        picked.bytes,
        fileName: picked.name,
        product: data,
      );
      if (!mounted) return;
      setState(() {
        _template = template;
        _templateEdits = {};
        _showTemplateErrors = false;
        _templateLoading = false;
      });
      _showMessage(
        'Template ready: ${template.mappedColumnCount} '
        'column${template.mappedColumnCount == 1 ? '' : 's'} matched.',
      );
    } on MeeshoTemplateException catch (error) {
      if (!mounted) return;
      setState(() {
        _templateError = error.message;
        _templateLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _templateError =
            'Could not read that template. Upload the original Meesho '
            '.xlsx file.';
        _templateLoading = false;
      });
    }
  }

  Future<void> _downloadTemplate() async {
    final template = _template;
    final data = _data;
    if (template == null || data == null || _templateSaving) return;
    final missing = widget.templateService.missingRequired(
      template,
      data,
      edits: _templateEdits,
    );
    if (missing.isNotEmpty) {
      setState(() {
        _showTemplateErrors = true;
        _templateError =
            'Fill the required fields before downloading: '
            '${missing.take(6).join(', ')}'
            '${missing.length > 6 ? ' and ${missing.length - 6} more' : ''}.';
      });
      return;
    }
    setState(() {
      _templateSaving = true;
      _templateError = null;
    });
    try {
      final bytes = widget.templateService.fill(
        template,
        data,
        edits: _templateEdits,
      );
      final fileName = _filledTemplateName(data.title, template.fileName);
      final saved = await (widget.templateSaver ?? _saveExcel)(bytes, fileName);
      if (!mounted) return;
      setState(() => _templateSaving = false);
      _showMessage(
        saved
            ? 'Filled Meesho Excel downloaded.'
            : 'Download is unavailable here.',
      );
    } on MeeshoTemplateException catch (error) {
      if (!mounted) return;
      setState(() {
        _templateError = error.message;
        _templateSaving = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _templateError =
            'Could not build the Excel file. Check the template and try again.';
        _templateSaving = false;
      });
    }
  }

  Future<bool> _saveExcel(Uint8List bytes, String fileName) {
    return downloadBytes(
      bytes,
      fileName,
      mimeType:
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
  }

  String _filledTemplateName(String title, String templateName) {
    final fallback = templateName.toLowerCase().endsWith('.xlsx')
        ? templateName.substring(0, templateName.length - 5)
        : templateName;
    final raw = title.trim().isNotEmpty ? title : fallback;
    var base = raw
        .replaceAll(RegExp(r'[<>:"/\\|?*]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    if (base.length > 60) base = base.substring(0, 60);
    if (base.isEmpty) base = 'Meesho_listing';
    return '${base}_meesho.xlsx';
  }

  Future<void> _copyValue(String label, String value) async {
    final text = value.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _showMessage('$label copied.');
  }

  Future<void> _copyPhotoLink(ProductLinkData data, int index) async {
    await _copyValue('Photo ${index + 1} link', data.photos[index].url);
  }

  Future<void> _copyAllPhotoLinks(ProductLinkData data) async {
    await _copyValue(
      'All photo links',
      data.photos.map((photo) => photo.url).join('\n'),
    );
  }

  Future<void> _copySummary(ProductLinkData data) async {
    final buffer = StringBuffer()
      ..writeln('Product title')
      ..writeln(data.title)
      ..writeln()
      ..writeln('Store: ${data.siteName}')
      ..writeln('Product URL: ${data.sourceUrl}');
    if (data.brand.isNotEmpty) buffer.writeln('Brand: ${data.brand}');
    if (data.category.isNotEmpty) buffer.writeln('Category: ${data.category}');
    if (data.price.isNotEmpty) buffer.writeln('Price: ${data.price}');
    if (data.mrp.isNotEmpty) buffer.writeln('MRP: ${data.mrp}');
    if (data.discount.isNotEmpty) buffer.writeln('Discount: ${data.discount}');
    if (data.rating.isNotEmpty) buffer.writeln('Rating: ${data.rating}');
    if (data.reviewCount.isNotEmpty) {
      buffer.writeln('Reviews: ${data.reviewCount}');
    }
    if (data.availability.isNotEmpty) {
      buffer.writeln('Availability: ${data.availability}');
    }
    if (data.seller.isNotEmpty) buffer.writeln('Seller: ${data.seller}');
    if (data.sku.isNotEmpty) buffer.writeln('SKU: ${data.sku}');
    if (data.description.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Description')
        ..writeln(data.description);
    }
    if (data.keyFeatures.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Key features');
      for (final feature in data.keyFeatures) {
        buffer.writeln('- $feature');
      }
    }
    if (data.keywords.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Keywords: ${data.keywords.join(', ')}');
    }
    if (data.specs.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Specifications');
      for (final spec in data.specs) {
        buffer.writeln('${spec.label}: ${spec.value}');
      }
    }
    if (data.photos.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Photo links');
      for (var i = 0; i < data.photos.length; i++) {
        buffer.writeln('${i + 1}. ${data.photos[i].url}');
      }
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString().trim()));
    if (mounted) _showMessage('All product details copied.');
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return ListView(
      padding: AppDimens.pagePadding(
        context,
      ).add(const EdgeInsets.only(top: AppDimens.lg, bottom: AppDimens.xxxl)),
      children: [
        const _AnalyzerHero(),
        const SizedBox(height: AppDimens.lg),
        _LinkInput(
          controller: _linkController,
          loading: _loading,
          onSubmitted: (value) => _fetch(raw: value),
          onPaste: _paste,
          onClear: _clear,
        ),
        const SizedBox(height: AppDimens.md),
        Wrap(
          spacing: AppDimens.sm,
          runSpacing: AppDimens.sm,
          children: [
            AppButton(
              label: _loading ? 'Reading product...' : 'Fetch product data',
              icon: Icons.auto_awesome,
              onPressed: () => _fetch(),
            ),
            AppButton(
              label: 'Paste from clipboard',
              icon: Icons.content_paste,
              variant: AppButtonVariant.outline,
              onPressed: _paste,
            ),
          ],
        ),
        if (_loading) ...[
          const SizedBox(height: AppDimens.xl),
          const _ReadingCard(),
        ],
        if (_error != null) ...[
          const SizedBox(height: AppDimens.xl),
          _ErrorCard(message: _error!, onRetry: () => _fetch()),
        ],
        if (!_loading && _error == null && data == null) ...[
          const SizedBox(height: AppDimens.xl),
          const EmptyState(
            icon: Icons.link,
            title: 'Paste a product link',
            message:
                'Use the full URL of a public product page. The app will pull '
                'the photos, title, description, features, keywords, price, '
                'rating, and specifications.',
          ),
        ],
        if (data != null) ...[
          const SizedBox(height: AppDimens.xl),
          _ProductHeader(
            data: data,
            onOpen: () => _openLink(data.sourceUrl),
            onCopy: () => _copySummary(data),
          ),
          const SizedBox(height: AppDimens.lg),
          _MeeshoTemplateCard(
            template: _template,
            showErrors: _showTemplateErrors,
            calculated: () => _template == null
                ? const []
                : widget.templateService.calculatedFields(
                    _template!,
                    data,
                    edits: _templateEdits,
                  ),
            defaults: _template == null
                ? const {}
                : widget.templateService.defaultValues(_template!, data),
            onEdit: (columnIndex, value) {
              // Only differences from the product value are kept as edits.
              final defaults = widget.templateService.defaultValues(
                _template!,
                data,
              );
              if (value == (defaults[columnIndex] ?? '')) {
                _templateEdits.remove(columnIndex);
              } else {
                _templateEdits[columnIndex] = value;
              }
            },
            onGenerate: _seo == null ? null : _generateSeo,
            loading: _templateLoading,
            saving: _templateSaving,
            error: _templateError,
            onPick: _chooseTemplate,
            onDownload: _downloadTemplate,
          ),
          if (data.photos.isNotEmpty) ...[
            const SizedBox(height: AppDimens.xl),
            SectionHeader(
              title: 'Product photos',
              subtitle:
                  '${data.photos.length} image${data.photos.length == 1 ? '' : 's'} found. Download a single photo, copy its link, or save them all.',
              action: Wrap(
                spacing: AppDimens.sm,
                runSpacing: AppDimens.sm,
                children: [
                  TextButton.icon(
                    onPressed: () => _copyAllPhotoLinks(data),
                    icon: const Icon(Icons.copy_all_outlined, size: 18),
                    label: const Text('Copy links'),
                  ),
                  TextButton.icon(
                    onPressed: () => _downloadAll(data),
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('Download all'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppDimens.lg),
            AdaptiveGrid(
              minItemWidth: 150,
              children: [
                for (var i = 0; i < data.photos.length; i++)
                  _PhotoCard(
                    photo: data.photos[i],
                    index: i,
                    onDownload: () => _downloadPhoto(data, i),
                    onCopyLink: () => _copyPhotoLink(data, i),
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppDimens.xl),
          _ListingDetails(
            data: data,
            onCopyAll: () => _copySummary(data),
            onCopy: _copyValue,
          ),
          const SizedBox(height: AppDimens.xl),
          _DetailsGrid(data: data),
          if (data.description.isNotEmpty) ...[
            const SizedBox(height: AppDimens.xl),
            _TextSection(
              icon: Icons.subject,
              title: 'Description',
              onCopy: () => _copyValue('Description', data.description),
              child: Text(
                data.description,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(height: 1.5),
              ),
            ),
          ],
          if (data.keyFeatures.isNotEmpty) ...[
            const SizedBox(height: AppDimens.xl),
            _TextSection(
              icon: Icons.checklist,
              title: 'Key features',
              onCopy: () => _copyValue(
                'Key features',
                data.keyFeatures.map((feature) => '- $feature').join('\n'),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < data.keyFeatures.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppDimens.sm),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppColors.success.withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '${i + 1}',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: AppColors.success,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                          ),
                          const SizedBox(width: AppDimens.sm),
                          Expanded(
                            child: Text(
                              data.keyFeatures[i],
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(height: 1.4),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Copy feature ${i + 1}',
                            onPressed: () => _copyValue(
                              'Feature ${i + 1}',
                              data.keyFeatures[i],
                            ),
                            icon: const Icon(Icons.copy_rounded, size: 17),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (data.keywords.isNotEmpty) ...[
            const SizedBox(height: AppDimens.xl),
            _TextSection(
              icon: Icons.tag,
              title: 'Keywords',
              onCopy: () => _copyValue('Keywords', data.keywords.join(', ')),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final chipMaxWidth = constraints.maxWidth > 320
                      ? 320.0
                      : constraints.maxWidth;
                  final textMaxWidth = chipMaxWidth > 120
                      ? chipMaxWidth - 44
                      : chipMaxWidth;
                  return Wrap(
                    spacing: AppDimens.sm,
                    runSpacing: AppDimens.sm,
                    children: [
                      for (final keyword in data.keywords)
                        Tooltip(
                          message: 'Copy $keyword',
                          child: InkWell(
                            borderRadius: BorderRadius.circular(
                              AppDimens.radiusPill,
                            ),
                            onTap: () => _copyValue('Keyword', keyword),
                            child: Container(
                              constraints: BoxConstraints(
                                maxWidth: chipMaxWidth,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppDimens.md,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary
                                    .withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(
                                  AppDimens.radiusPill,
                                ),
                                border: Border.all(
                                  color: Theme.of(context).colorScheme.primary
                                      .withValues(alpha: 0.18),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth: textMaxWidth,
                                    ),
                                    child: Text(
                                      keyword,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(
                                    Icons.copy_rounded,
                                    size: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
          if (data.hasSpecs) ...[
            const SizedBox(height: AppDimens.xl),
            _SpecsSection(
              specs: data.specs,
              onCopyAll: () => _copyValue(
                'Specifications',
                data.specs
                    .map((spec) => '${spec.label}: ${spec.value}')
                    .join('\n'),
              ),
              onCopy: (spec) =>
                  _copyValue(spec.label, '${spec.label}: ${spec.value}'),
            ),
          ],
        ],
      ],
    );
  }
}

class _AnalyzerHero extends StatelessWidget {
  const _AnalyzerHero();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppDimens.xl),
      decoration: BoxDecoration(
        gradient: AppColors.hero,
        borderRadius: BorderRadius.circular(AppDimens.radiusLg),
        boxShadow: AppColors.heroShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Product Link Analyzer',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              height: 1.15,
            ),
          ),
          const SizedBox(height: AppDimens.sm),
          Text(
            'Paste a product URL from Flipkart, Amazon, Meesho, Myntra, or '
            'any public store. Get listing-ready photos, copy, keywords, '
            'features, and specifications in one place.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.86),
              height: 1.4,
            ),
          ),
          const SizedBox(height: AppDimens.lg),
          Wrap(
            spacing: AppDimens.sm,
            runSpacing: AppDimens.sm,
            children: const [
              _HeroBadge(icon: Icons.public, label: 'No API key'),
              _HeroBadge(icon: Icons.photo_library_outlined, label: 'Photos'),
              _HeroBadge(icon: Icons.text_snippet_outlined, label: 'Copy data'),
              _HeroBadge(icon: Icons.tune, label: 'Specs & keywords'),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroBadge extends StatelessWidget {
  const _HeroBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.md,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppDimens.radiusPill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _LinkInput extends StatelessWidget {
  const _LinkInput({
    required this.controller,
    required this.loading,
    required this.onSubmitted,
    required this.onPaste,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool loading;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onPaste;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      padding: const EdgeInsets.all(AppDimens.md),
      shadow: false,
      child: TextField(
        controller: controller,
        minLines: 1,
        maxLines: 2,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.go,
        enabled: !loading,
        onSubmitted: onSubmitted,
        decoration: InputDecoration(
          hintText: 'https://www.flipkart.com/product-link',
          prefixIcon: const Icon(Icons.link),
          border: InputBorder.none,
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Paste from clipboard',
                onPressed: loading ? null : onPaste,
                icon: const Icon(Icons.content_paste),
              ),
              IconButton(
                tooltip: 'Clear link',
                onPressed: loading ? null : onClear,
                icon: Icon(Icons.close, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadingCard extends StatelessWidget {
  const _ReadingCard();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      shadow: false,
      child: Column(
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          const SizedBox(height: AppDimens.md),
          Text(
            'Reading the product page...',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppDimens.xs),
          Text(
            'Pulling metadata, JSON-LD, photos, and page copy.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppDimens.md),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(AppDimens.radiusSm),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
          const SizedBox(width: AppDimens.sm),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _MeeshoTemplateCard extends StatelessWidget {
  const _MeeshoTemplateCard({
    required this.template,
    required this.defaults,
    required this.onEdit,
    required this.showErrors,
    required this.calculated,
    required this.onGenerate,
    required this.loading,
    required this.saving,
    required this.error,
    required this.onPick,
    required this.onDownload,
  });

  final MeeshoTemplate? template;
  final Map<int, String> defaults;
  final void Function(int columnIndex, String value) onEdit;
  final bool showErrors;
  final List<MeeshoCalculatedField> Function() calculated;
  final Future<String?> Function(MeeshoTemplateColumn column, String current)?
  onGenerate;
  final bool loading;
  final bool saving;
  final String? error;
  final VoidCallback onPick;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = template;
    final mapped = current?.mappedColumns ?? const <MeeshoTemplateColumn>[];

    return AppCard(
      shadow: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppDimens.radiusSm),
                ),
                child: const Icon(
                  Icons.table_view_outlined,
                  color: AppColors.success,
                  size: 22,
                ),
              ),
              const SizedBox(width: AppDimens.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Meesho listing Excel',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: AppDimens.xs),
                    Text(
                      'Upload your Meesho template. This product will be '
                      'filled into it and downloaded as an .xlsx file.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: AppDimens.md),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppDimens.md),
              decoration: BoxDecoration(
                color: scheme.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppDimens.radiusSm),
                border: Border.all(color: scheme.error.withValues(alpha: 0.2)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, color: scheme.error, size: 18),
                  const SizedBox(width: AppDimens.sm),
                  Expanded(
                    child: Text(
                      error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (current == null) ...[
            const SizedBox(height: AppDimens.lg),
            AppButton(
              label: loading ? 'Reading template...' : 'Upload Meesho template',
              icon: Icons.upload_file_outlined,
              variant: AppButtonVariant.outline,
              onPressed: loading ? null : onPick,
            ),
            const SizedBox(height: AppDimens.sm),
            Text(
              'Use the original template downloaded from Meesho. The header '
              'row and product-specific columns are detected automatically.',
              style: theme.textTheme.bodySmall,
            ),
          ] else ...[
            const SizedBox(height: AppDimens.lg),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppDimens.md),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(AppDimens.radiusSm),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.16),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.description_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: AppDimens.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          current.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${current.sheetName} · header row '
                          '${current.headerRowNumber} · data row '
                          '${current.dataRowNumber}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppDimens.md),
            Text(
              '${mapped.length} of ${current.columns.length} columns matched. '
              'Review the values below. Edit any field or fill the ones that '
              'are missing; empty fields stay as they are in the template.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppDimens.md),
            _TemplateFieldsEditor(
              key: ObjectKey(current),
              columns: current.columns,
              defaults: defaults,
              onEdit: onEdit,
              showErrors: showErrors,
              calculated: calculated,
              onGenerate: onGenerate,
            ),
            const SizedBox(height: AppDimens.lg),
            Wrap(
              spacing: AppDimens.sm,
              runSpacing: AppDimens.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                AppButton(
                  label: saving ? 'Building Excel...' : 'Download filled Excel',
                  icon: Icons.download_outlined,
                  onPressed: saving ? null : onDownload,
                ),
                TextButton.icon(
                  onPressed: loading || saving ? null : onPick,
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: const Text('Choose another'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// One editable field per template column: matched columns come pre-filled
/// from the product, the rest start empty so missing data can be added.
class _TemplateFieldsEditor extends StatefulWidget {
  const _TemplateFieldsEditor({
    super.key,
    required this.columns,
    required this.defaults,
    required this.onEdit,
    required this.showErrors,
    required this.calculated,
    this.onGenerate,
  });

  final List<MeeshoTemplateColumn> columns;
  final Map<int, String> defaults;
  final void Function(int columnIndex, String value) onEdit;
  final bool showErrors;
  final List<MeeshoCalculatedField> Function() calculated;
  final Future<String?> Function(MeeshoTemplateColumn column, String current)?
  onGenerate;

  @override
  State<_TemplateFieldsEditor> createState() => _TemplateFieldsEditorState();
}

class _TemplateFieldsEditorState extends State<_TemplateFieldsEditor> {
  late final Map<int, TextEditingController> _controllers = {
    for (final column in widget.columns)
      column.columnIndex: TextEditingController(
        text: widget.defaults[column.columnIndex] ?? '',
      ),
  };

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  final Map<int, FocusNode> _focusNodes = {};

  Widget _field(MeeshoTemplateColumn column) =>
      column.options.isEmpty ? _textField(column) : _choiceField(column);

  /// A searchable dropdown limited to the template's own choices.
  Widget _choiceField(MeeshoTemplateColumn column) {
    final controller = _controllers[column.columnIndex]!;
    final focusNode = _focusNodes.putIfAbsent(
      column.columnIndex,
      () => FocusNode(),
    );
    final text = controller.text.trim();
    final invalid = text.isNotEmpty && column.matchOption(text) == null;
    final missing =
        widget.showErrors &&
        column.required &&
        !column.prefilled &&
        text.isEmpty;

    void apply(String value) {
      widget.onEdit(column.columnIndex, column.matchOption(value) ?? '');
      setState(() {});
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.md),
      child: LayoutBuilder(
        builder: (context, constraints) => RawAutocomplete<String>(
          textEditingController: controller,
          focusNode: focusNode,
          optionsBuilder: (value) {
            final query = value.text.trim().toLowerCase();
            if (query.isEmpty || column.matchOption(value.text) != null) {
              return column.options;
            }
            return column.options.where(
              (option) => option.toLowerCase().contains(query),
            );
          },
          onSelected: apply,
          fieldViewBuilder: (context, textController, node, onSubmitted) {
            return TextField(
              controller: textController,
              focusNode: node,
              onChanged: apply,
              decoration: InputDecoration(
                labelText: column.required
                    ? '${column.header} *'
                    : column.header,
                errorText: missing
                    ? 'Required'
                    : invalid
                    ? 'Choose a value from the list'
                    : null,
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Show options',
                  icon: const Icon(Icons.arrow_drop_down),
                  onPressed: () {
                    if (node.hasFocus) node.unfocus();
                    node.requestFocus();
                  },
                ),
              ),
            );
          },
          optionsViewBuilder: (context, onSelected, options) {
            final list = options.toList(growable: false);
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(AppDimens.radiusSm),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: 240,
                    maxWidth: constraints.maxWidth,
                  ),
                  child: list.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(AppDimens.md),
                          child: Text('No matching option'),
                        )
                      : ListView.builder(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          itemCount: list.length,
                          itemBuilder: (context, index) => ListTile(
                            dense: true,
                            title: Text(list[index]),
                            onTap: () => onSelected(list[index]),
                          ),
                        ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _textField(MeeshoTemplateColumn column) {
    final controller = _controllers[column.columnIndex]!;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimens.md),
      child: TextField(
        controller: controller,
        minLines: 1,
        maxLines: 4,
        onChanged: (value) {
          widget.onEdit(column.columnIndex, value);
          setState(() {});
        },
        decoration: InputDecoration(
          labelText: column.required ? '${column.header} *' : column.header,
          errorText:
              widget.showErrors &&
                  column.required &&
                  !column.prefilled &&
                  controller.text.trim().isEmpty
              ? 'Required'
              : null,
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_canGenerate(column))
                _generating.contains(column.columnIndex)
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        tooltip: controller.text.trim().isEmpty
                            ? 'Generate with AI'
                            : 'Regenerate with AI',
                        icon: const Icon(Icons.auto_awesome, size: 18),
                        onPressed: () => _generate(column),
                      ),
              IconButton(
                tooltip: 'Reset to product value',
                icon: const Icon(Icons.restart_alt, size: 18),
                onPressed: () {
                  controller.text = widget.defaults[column.columnIndex] ?? '';
                  widget.onEdit(column.columnIndex, controller.text);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  final Set<int> _generating = {};

  /// The AI button sits inside the product title and description fields.
  bool _canGenerate(MeeshoTemplateColumn column) =>
      widget.onGenerate != null &&
      (column.fieldKey == 'title' || column.fieldKey == 'description');

  Future<void> _generate(MeeshoTemplateColumn column) async {
    final controller = _controllers[column.columnIndex]!;
    setState(() => _generating.add(column.columnIndex));
    final text = await widget.onGenerate!(column, controller.text);
    if (!mounted) return;
    setState(() {
      _generating.remove(column.columnIndex);
      if (text != null && text.isNotEmpty) {
        controller.text = text;
        widget.onEdit(column.columnIndex, text);
      }
    });
  }

  List<Widget> _calculatedTiles(ThemeData theme) => [
    for (final field in widget.calculated())
      Padding(
        padding: const EdgeInsets.only(bottom: AppDimens.md),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: '${field.header} (auto-calculated)',
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          child: Text(
            field.value.isEmpty ? '-' : '₹${field.value}',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editable = widget.columns.where((c) => c.editable);
    final mapped = editable.where((c) => c.required && !c.prefilled).toList();
    final others = editable
        .where((c) => !(c.required && !c.prefilled))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (mapped.isNotEmpty) ...[
          Text(
            'Required fields (${mapped.length})',
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'All of these must be filled before you can download.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppDimens.sm),
          for (final column in mapped) ...[
            _field(column),
            // The template's own price formulas sit right after the price.
            if (column.fieldKey == 'price') ..._calculatedTiles(theme),
          ],
        ],
        if (others.isNotEmpty)
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(top: AppDimens.sm),
              title: Text(
                'Optional fields (${others.length})',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: const Text('Not required. Edit or fill if needed.'),
              children: [
                for (final column in others) ...[
                  _field(column),
                  if (column.fieldKey == 'price') ..._calculatedTiles(theme),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _ProductHeader extends StatelessWidget {
  const _ProductHeader({
    required this.data,
    required this.onOpen,
    required this.onCopy,
  });

  final ProductLinkData data;
  final VoidCallback onOpen;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final image = _HeaderPhoto(data: data);
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppDimens.xs,
          runSpacing: AppDimens.xs,
          children: [
            _Pill(
              icon: Icons.storefront_outlined,
              label: data.siteName,
              color: scheme.primary,
            ),
            if (data.availability.isNotEmpty)
              _Pill(
                icon: Icons.inventory_2_outlined,
                label: data.availability,
                color: data.availability.toLowerCase().contains('in stock')
                    ? AppColors.success
                    : AppColors.warning,
              ),
          ],
        ),
        const SizedBox(height: AppDimens.sm),
        Text(
          data.title,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1.25,
          ),
        ),
        const SizedBox(height: AppDimens.xs),
        Text(
          data.sourceHost.isEmpty ? data.siteName : data.sourceHost,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        if (data.price.isNotEmpty) ...[
          const SizedBox(height: AppDimens.md),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AppDimens.sm,
            runSpacing: 4,
            children: [
              Text(
                data.price,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: AppColors.success,
                ),
              ),
              if (data.mrp.isNotEmpty)
                Text(
                  data.mrp,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    decoration: TextDecoration.lineThrough,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              if (data.discount.isNotEmpty)
                Text(
                  data.discount,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: AppColors.success,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ],
        if (data.rating.isNotEmpty) ...[
          const SizedBox(height: AppDimens.xs),
          Row(
            children: [
              const Icon(
                Icons.star_rounded,
                size: 18,
                color: Color(0xFFF59E0B),
              ),
              const SizedBox(width: 4),
              Text(
                data.rating,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (data.reviewCount.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(
                  '(${data.reviewCount} ratings)',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ],
        if (data.quickFacts.isNotEmpty) ...[
          const SizedBox(height: AppDimens.md),
          Wrap(
            spacing: AppDimens.sm,
            runSpacing: AppDimens.sm,
            children: [
              for (final entry in data.quickFacts.entries)
                _FactChip(label: entry.key, value: entry.value),
            ],
          ),
        ],
        const SizedBox(height: AppDimens.lg),
        Wrap(
          spacing: AppDimens.sm,
          runSpacing: AppDimens.sm,
          children: [
            AppButton(
              label: 'Open product page',
              icon: Icons.open_in_new,
              onPressed: onOpen,
            ),
            AppButton(
              label: 'Copy details',
              icon: Icons.copy_all_outlined,
              variant: AppButtonVariant.outline,
              onPressed: onCopy,
            ),
          ],
        ),
      ],
    );

    return AppCard(
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 620) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                image,
                const SizedBox(height: AppDimens.lg),
                info,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 190, child: image),
              const SizedBox(width: AppDimens.xl),
              Expanded(child: info),
            ],
          );
        },
      ),
    );
  }
}

class _HeaderPhoto extends StatelessWidget {
  const _HeaderPhoto({required this.data});

  final ProductLinkData data;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(AppDimens.radiusMd),
          border: Border.all(color: scheme.outline),
        ),
        clipBehavior: Clip.antiAlias,
        child: data.photos.isEmpty
            ? Icon(
                Icons.image_not_supported_outlined,
                size: 42,
                color: scheme.onSurfaceVariant,
              )
            : Image.network(
                data.photos.first.url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(
                  Icons.broken_image_outlined,
                  size: 42,
                  color: scheme.onSurfaceVariant,
                ),
              ),
      ),
    );
  }
}

class _PhotoCard extends StatelessWidget {
  const _PhotoCard({
    required this.photo,
    required this.index,
    required this.onDownload,
    required this.onCopyLink,
  });

  final ProductPhoto photo;
  final int index;
  final VoidCallback onDownload;
  final VoidCallback onCopyLink;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      padding: EdgeInsets.zero,
      shadow: false,
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              child: Image.network(
                photo.url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(
                  Icons.broken_image_outlined,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PhotoAction(
                    tooltip: 'Copy photo ${index + 1} link',
                    icon: Icons.copy_rounded,
                    onPressed: onCopyLink,
                  ),
                  const SizedBox(width: 4),
                  _PhotoAction(
                    tooltip: 'Download photo ${index + 1}',
                    icon: Icons.download_outlined,
                    onPressed: onDownload,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoAction extends StatelessWidget {
  const _PhotoAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.9),
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: 19),
        color: AppColors.accent,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _ListingDetails extends StatelessWidget {
  const _ListingDetails({
    required this.data,
    required this.onCopyAll,
    required this.onCopy,
  });

  final ProductLinkData data;
  final VoidCallback onCopyAll;
  final Future<void> Function(String label, String value) onCopy;

  @override
  Widget build(BuildContext context) {
    final rows = <MapEntry<String, String>>[
      MapEntry('Product title', data.title),
      if (data.siteName.isNotEmpty) MapEntry('Store', data.siteName),
      MapEntry('Product URL', data.sourceUrl),
      if (data.brand.isNotEmpty) MapEntry('Brand', data.brand),
      if (data.category.isNotEmpty) MapEntry('Category', data.category),
      if (data.price.isNotEmpty) MapEntry('Price', data.price),
      if (data.mrp.isNotEmpty) MapEntry('MRP', data.mrp),
      if (data.discount.isNotEmpty) MapEntry('Discount', data.discount),
      if (data.rating.isNotEmpty) MapEntry('Rating', data.rating),
      if (data.reviewCount.isNotEmpty) MapEntry('Reviews', data.reviewCount),
      if (data.availability.isNotEmpty)
        MapEntry('Availability', data.availability),
      if (data.seller.isNotEmpty) MapEntry('Seller', data.seller),
      if (data.sku.isNotEmpty) MapEntry('SKU', data.sku),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Listing details',
          subtitle: 'Every field is separate. Copy one field or copy the full listing.',
          action: TextButton.icon(
            onPressed: onCopyAll,
            icon: const Icon(Icons.copy_all_outlined, size: 18),
            label: const Text('Copy all'),
          ),
        ),
        const SizedBox(height: AppDimens.md),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++)
                _ListingDetailRow(
                  label: rows[i].key,
                  value: rows[i].value,
                  showDivider: i != rows.length - 1,
                  onCopy: () => onCopy(rows[i].key, rows[i].value),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ListingDetailRow extends StatelessWidget {
  const _ListingDetailRow({
    required this.label,
    required this.value,
    required this.showDivider,
    required this.onCopy,
  });

  final String label;
  final String value;
  final bool showDivider;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.only(
        left: AppDimens.lg,
        right: AppDimens.sm,
        top: AppDimens.sm,
        bottom: AppDimens.sm,
      ),
      decoration: BoxDecoration(
        border: showDivider
            ? Border(
                bottom: BorderSide(
                  color: scheme.outline.withValues(alpha: 0.6),
                ),
              )
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: AppDimens.sm),
          Expanded(
            child: SelectableText(
              value,
              maxLines: 4,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
            ),
          ),
          IconButton(
            tooltip: 'Copy ${label.toLowerCase()}',
            onPressed: onCopy,
            icon: const Icon(Icons.copy_rounded, size: 17),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _DetailsGrid extends StatelessWidget {
  const _DetailsGrid({required this.data});

  final ProductLinkData data;

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[];
    if (data.description.isNotEmpty) {
      cards.add(
        _MiniStat(
          icon: Icons.subject,
          label: 'Description',
          value: '${data.description.length} chars',
        ),
      );
    }
    if (data.keyFeatures.isNotEmpty) {
      cards.add(
        _MiniStat(
          icon: Icons.checklist,
          label: 'Key features',
          value: '${data.keyFeatures.length}',
        ),
      );
    }
    if (data.keywords.isNotEmpty) {
      cards.add(
        _MiniStat(
          icon: Icons.tag,
          label: 'Keywords',
          value: '${data.keywords.length}',
        ),
      );
    }
    if (data.specs.isNotEmpty) {
      cards.add(
        _MiniStat(
          icon: Icons.tune,
          label: 'Specifications',
          value: '${data.specs.length}',
        ),
      );
    }
    if (cards.isEmpty) return const SizedBox.shrink();
    return AdaptiveGrid(
      minItemWidth: 150,
      spacing: AppDimens.md,
      runSpacing: AppDimens.md,
      children: cards,
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      padding: const EdgeInsets.all(AppDimens.md),
      shadow: false,
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(AppDimens.radiusSm),
            ),
            child: Icon(icon, size: 18, color: scheme.primary),
          ),
          const SizedBox(width: AppDimens.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TextSection extends StatelessWidget {
  const _TextSection({
    required this.icon,
    required this.title,
    required this.child,
    this.onCopy,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: title,
          action: onCopy == null
              ? null
              : TextButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy_rounded, size: 17),
                  label: const Text('Copy'),
                ),
        ),
        const SizedBox(height: AppDimens.md),
        AppCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: AppDimens.md),
              Expanded(child: child),
            ],
          ),
        ),
      ],
    );
  }
}

class _SpecsSection extends StatelessWidget {
  const _SpecsSection({
    required this.specs,
    required this.onCopyAll,
    required this.onCopy,
  });

  final List<ProductSpec> specs;
  final VoidCallback onCopyAll;
  final ValueChanged<ProductSpec> onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Specifications',
          action: TextButton.icon(
            onPressed: onCopyAll,
            icon: const Icon(Icons.copy_all_outlined, size: 18),
            label: const Text('Copy all'),
          ),
        ),
        const SizedBox(height: AppDimens.md),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < specs.length; i++)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppDimens.lg,
                    vertical: AppDimens.md,
                  ),
                  decoration: BoxDecoration(
                    color: i.isOdd
                        ? scheme.surfaceContainerHighest.withValues(alpha: 0.22)
                        : null,
                    border: i == 0
                        ? null
                        : Border(
                            top: BorderSide(
                              color: scheme.outline.withValues(alpha: 0.6),
                            ),
                          ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 150,
                        child: Text(
                          specs[i].label,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppDimens.md),
                      Expanded(
                        child: Text(
                          specs[i].value,
                          style: theme.textTheme.bodySmall?.copyWith(
                            height: 1.4,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy ${specs[i].label}',
                        onPressed: () => onCopy(specs[i]),
                        icon: const Icon(Icons.copy_rounded, size: 17),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppDimens.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _FactChip extends StatelessWidget {
  const _FactChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.md,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppDimens.radiusSm),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.7)),
      ),
      child: RichText(
        text: TextSpan(
          style: Theme.of(context).textTheme.labelSmall,
          children: [
            TextSpan(
              text: '$label: ',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            TextSpan(
              text: value,
              style: TextStyle(
                color: scheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _photoFileName(String title, int index, String url) {
  var base = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (base.isEmpty) base = 'product';
  if (base.length > 60) base = base.substring(0, 60);
  final lower = url.toLowerCase();
  final extension = lower.contains('.png')
      ? 'png'
      : lower.contains('.webp')
      ? 'webp'
      : lower.contains('.gif')
      ? 'gif'
      : 'jpg';
  return '$base-photo-${index + 1}.$extension';
}

/// Asks for the Groq API key used to write SEO titles and descriptions. The key
/// stays on this device.
class _GroqKeyDialog extends StatefulWidget {
  const _GroqKeyDialog({required this.service});

  final SeoService service;

  @override
  State<_GroqKeyDialog> createState() => _GroqKeyDialogState();
}

class _GroqKeyDialogState extends State<_GroqKeyDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      await widget.service.connect(_controller.text);
      if (mounted) Navigator.of(context).pop(true);
    } on SeoException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Groq API key'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'The key is used to write the SEO title and description. It is '
            'saved on this device only. Create a free key at console.groq.com.',
          ),
          const SizedBox(height: AppDimens.md),
          TextField(
            controller: _controller,
            obscureText: _obscure,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Groq API key',
              errorText: _error,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Show key' : 'Hide key',
                icon: Icon(
                  _obscure ? Icons.visibility_outlined : Icons.visibility_off,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save key')),
      ],
    );
  }
}
