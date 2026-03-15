import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/summary_section.dart';
import '../models/tender_result.dart';
import '../services/advanced_search_service.dart';
import '../services/captcha_service.dart';
import '../services/tender_service.dart' show CaptchaRejectedError;

const _maxAutoRetries = 10;

// ── Main Screen ───────────────────────────────────────────────────────────────

class AdvancedSearchScreen extends StatefulWidget {
  const AdvancedSearchScreen({super.key});

  @override
  State<AdvancedSearchScreen> createState() => _AdvancedSearchScreenState();
}

class _AdvancedSearchScreenState extends State<AdvancedSearchScreen> {
  final _service = AdvancedSearchService();

  // Text controllers
  final _tenderIdCtrl = TextEditingController();
  final _tenderRefCtrl = TextEditingController();
  final _workTitleCtrl = TextEditingController();
  final _pincodeCtrl = TextEditingController();
  final _fromValueCtrl = TextEditingController();
  final _toValueCtrl = TextEditingController();
  final _captchaCtrl = TextEditingController();

  // Static dropdown state — '0' means "all / unselected" (matches site's POST values)
  String _tenderType = '0';
  String _organisation = '0';
  String _tenderCategory = '0';
  String _productCategory = '0';
  String _formOfContract = '0';
  String _paymentMode = '0';
  String _valueCriteria = '0';
  String _valueParameter = '0';
  String _dateCriteria = '0';
  DateTime? _fromDate;
  DateTime? _toDate;

  // Cascading dropdown state — '0' means "all"
  String _department = '0';
  String _division = '0';
  String _subDivision = '0';
  String _branch = '0';
  List<AdvSelectOption>? _deptOptions;
  List<AdvSelectOption>? _divOptions;
  List<AdvSelectOption>? _subDivOptions;
  List<AdvSelectOption>? _branchOptions;
  bool _loadingDept = false;
  bool _loadingDiv = false;
  bool _loadingSubDiv = false;
  bool _loadingBranch = false;

  // Checkbox state
  bool _twoStage = false;
  bool _nda = false;
  bool _preferential = false;
  bool _gte = false;
  bool _ite = false;
  bool _tenderFeeExemption = false;
  bool _emdExemption = false;

  _Phase _phase = const _PhaseInit();
  Map<String, String>? _savedParams;

  // Static dropdown options
  static const _tenderTypes = [
    AdvSelectOption('0', 'All Types'),
    AdvSelectOption('1', 'Open Tender'),
    AdvSelectOption('2', 'Limited Tender'),
  ];
  static const _tenderCategories = [
    AdvSelectOption('0', 'All Categories'),
    AdvSelectOption('1', 'Goods'),
    AdvSelectOption('2', 'Services'),
    AdvSelectOption('3', 'Works'),
  ];
  static const _formsOfContract = [
    AdvSelectOption('0', 'All'),
    AdvSelectOption('1', 'Buy'),
    AdvSelectOption('2', 'Empanelment'),
    AdvSelectOption('3', 'EOI'),
    AdvSelectOption('4', 'Fixed-rate'),
    AdvSelectOption('5', 'Item Rate'),
    AdvSelectOption('6', 'Item Wise'),
    AdvSelectOption('7', 'Lump-sum'),
    AdvSelectOption('8', 'Multi-stage'),
    AdvSelectOption('9', 'Percentage'),
    AdvSelectOption('10', 'Piece-work'),
    AdvSelectOption('11', 'PPP-BoT-Annuity'),
    AdvSelectOption('12', 'Tender cum Auction'),
    AdvSelectOption('13', 'Turn-key'),
  ];
  static const _paymentModes = [
    AdvSelectOption('0', 'All'),
    AdvSelectOption('1', 'Offline'),
    AdvSelectOption('2', 'Online'),
    AdvSelectOption('3', 'Both(Online/Offline)'),
    AdvSelectOption('4', 'Not Applicable'),
  ];
  static const _valueCriterias = [
    AdvSelectOption('0', 'None'),
    AdvSelectOption('1', 'EMD'),
    AdvSelectOption('2', 'Tender Fee'),
    AdvSelectOption('3', 'Processing Fee'),
    AdvSelectOption('4', 'ECV'),
  ];
  static const _valueParameters = [
    AdvSelectOption('0', 'All'),
    AdvSelectOption('1', 'Equal'),
    AdvSelectOption('2', 'Less Than'),
    AdvSelectOption('3', 'Greater Than'),
    AdvSelectOption('4', 'Between'),
  ];
  static const _dateCriterias = [
    AdvSelectOption('0', 'None'),
    AdvSelectOption('1', 'Published Date'),
    AdvSelectOption('2', 'Doc Download Start'),
    AdvSelectOption('3', 'Doc Download End'),
    AdvSelectOption('4', 'Bid Submission Start'),
    AdvSelectOption('5', 'Bid Submission End'),
  ];

  @override
  void initState() {
    super.initState();
    _loadForm();
  }

  @override
  void dispose() {
    _tenderIdCtrl.dispose();
    _tenderRefCtrl.dispose();
    _workTitleCtrl.dispose();
    _pincodeCtrl.dispose();
    _fromValueCtrl.dispose();
    _toValueCtrl.dispose();
    _captchaCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadForm() async {
    setState(() => _phase = const _PhaseInit());
    try {
      final meta = await _service.beginSession();
      if (mounted) setState(() => _phase = _PhaseForm(meta));
    } catch (e) {
      if (mounted) setState(() => _phase = _PhaseError(e.toString()));
    }
  }

  // ── Cascade handlers ───────────────────────────────────────────────────────

  void _onOrgChanged(String? v) {
    final org = v ?? '0';
    setState(() {
      _organisation = org;
      _department = '0';
      _division = '0';
      _subDivision = '0';
      _branch = '0';
      _deptOptions = null;
      _divOptions = null;
      _subDivOptions = null;
      _branchOptions = null;
    });
    if (org != '0') _fetchDepts(org);
  }

  void _onDeptChanged(String? v) {
    final dept = v ?? '0';
    setState(() {
      _department = dept;
      _division = '0';
      _subDivision = '0';
      _branch = '0';
      _divOptions = null;
      _subDivOptions = null;
      _branchOptions = null;
    });
    if (dept != '0') _fetchDivs(_organisation, dept);
  }

  void _onDivChanged(String? v) {
    final div = v ?? '0';
    setState(() {
      _division = div;
      _subDivision = '0';
      _branch = '0';
      _subDivOptions = null;
      _branchOptions = null;
    });
    if (div != '0') _fetchSubDivs(_organisation, _department, div);
  }

  void _onSubDivChanged(String? v) {
    final sd = v ?? '0';
    setState(() {
      _subDivision = sd;
      _branch = '0';
      _branchOptions = null;
    });
    if (sd != '0') {
      _fetchBranches(_organisation, _department, _division, sd);
    }
  }

  Future<void> _fetchDepts(String org) async {
    setState(() => _loadingDept = true);
    try {
      final opts = await _service.fetchDepartments(org);
      if (mounted) setState(() { _deptOptions = opts; _loadingDept = false; });
    } catch (_) {
      if (mounted) setState(() { _deptOptions = []; _loadingDept = false; });
    }
  }

  Future<void> _fetchDivs(String org, String dept) async {
    setState(() => _loadingDiv = true);
    try {
      final opts = await _service.fetchDivisions(org, dept);
      if (mounted) setState(() { _divOptions = opts; _loadingDiv = false; });
    } catch (_) {
      if (mounted) setState(() { _divOptions = []; _loadingDiv = false; });
    }
  }

  Future<void> _fetchSubDivs(String org, String dept, String div) async {
    setState(() => _loadingSubDiv = true);
    try {
      final opts = await _service.fetchSubDivisions(org, dept, div);
      if (mounted) setState(() { _subDivOptions = opts; _loadingSubDiv = false; });
    } catch (_) {
      if (mounted) setState(() { _subDivOptions = []; _loadingSubDiv = false; });
    }
  }

  Future<void> _fetchBranches(
      String org, String dept, String div, String subDiv) async {
    setState(() => _loadingBranch = true);
    try {
      final opts = await _service.fetchBranches(org, dept, div, subDiv);
      if (mounted) setState(() { _branchOptions = opts; _loadingBranch = false; });
    } catch (_) {
      if (mounted) setState(() { _branchOptions = []; _loadingBranch = false; });
    }
  }

  // ── Search ─────────────────────────────────────────────────────────────────

  Map<String, String> _buildParams() {
    return {
      'TenderType': _tenderType,
      'tenderId': _tenderIdCtrl.text.trim(),
      'OrganisationName': _organisation,
      'tenderRefNo': _tenderRefCtrl.text.trim(),
      'workItemTitle': _workTitleCtrl.text.trim(),
      'Department': _department,
      'tenderCategory': _tenderCategory,
      'Division': _division,
      'SubDivision': _subDivision,
      'ProductCategory': _productCategory,
      'Branch': _branch,
      'formContract': _formOfContract,
      'Block': '0',
      'pinCode': _pincodeCtrl.text.trim(),
      'PaymentMode': _paymentMode,
      'valueCriteria': _valueCriteria,
      'valueParameter': _valueParameter,
      'FromValue': _fromValueCtrl.text.trim(),
      'ToValue': _valueParameter == '4' ? _toValueCtrl.text.trim() : '',
      'dateCriteria': _dateCriteria,
      'fromDate': _fromDate != null ? _fmtDate(_fromDate!) : '',
      'toDate': _toDate != null ? _fmtDate(_toDate!) : '',
      if (_twoStage) 'twoStageAllowed': 'on',
      if (_nda) 'ndaAllowed': 'on',
      if (_preferential) 'prefBidAllowed': 'on',
      if (_gte) 'chkGteAllowed': 'on',
      if (_ite) 'chkIteAllowed': 'on',
      if (_tenderFeeExemption) 'chkTfeAllowed': 'on',
      if (_emdExemption) 'chkEfeAllowed': 'on',
    };
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/'
      '${d.year}';

  void _onSearch() {
    if (_tenderType == '0') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a Tender Type to search.')),
      );
      return;
    }
    _savedParams = _buildParams();
    _autoRetry(0);
  }

  Future<void> _autoRetry(int attempt) async {
    if (!mounted) return;
    setState(() => _phase = _PhaseSolving(attempt));
    try {
      final meta = await _service.beginSession();
      final captchaText = await CaptchaService.solve(meta.captchaBytes);

      if (captchaText.length < 4 || captchaText.length > 9) {
        if (attempt + 1 < _maxAutoRetries) return _autoRetry(attempt + 1);
        return _showManualCaptcha();
      }

      final page =
          await _service.submitSearch(_savedParams!, captchaText);
      if (mounted) setState(() => _phase = _PhaseResults(page));
    } on CaptchaRejectedError {
      if (attempt + 1 < _maxAutoRetries) {
        _autoRetry(attempt + 1);
      } else {
        _showManualCaptcha();
      }
    } catch (e) {
      if (mounted) setState(() => _phase = _PhaseError(e.toString()));
    }
  }

  Future<void> _showManualCaptcha() async {
    if (!mounted) return;
    try {
      final meta = await _service.beginSession();
      if (mounted) {
        setState(() => _phase = _PhaseManualCaptcha(meta.captchaBytes));
      }
    } catch (e) {
      if (mounted) setState(() => _phase = _PhaseError(e.toString()));
    }
  }

  Future<void> _submitManual() async {
    final text = _captchaCtrl.text.trim();
    if (text.isEmpty) return;
    if (!mounted) return;
    try {
      final page = await _service.submitSearch(_savedParams!, text);
      if (mounted) setState(() => _phase = _PhaseResults(page));
    } on CaptchaRejectedError {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wrong captcha — please try again.')),
        );
        _captchaCtrl.clear();
        _showManualCaptcha();
      }
    } catch (e) {
      if (mounted) setState(() => _phase = _PhaseError(e.toString()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Advanced Search'),
        centerTitle: true,
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          if (_phase is _PhaseResults || _phase is _PhaseError)
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: 'New Search',
              onPressed: _loadForm,
            ),
        ],
      ),
      body: SafeArea(top: false, child: _buildBody()),
    );
  }

  Widget _buildBody() {
    final p = _phase;

    if (p is _PhaseInit) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 14),
            Text('Loading form…', style: TextStyle(color: Colors.black54)),
          ],
        ),
      );
    }

    if (p is _PhaseForm) return _buildForm(p.meta);

    if (p is _PhaseSolving) {
      final label = p.attempt < 0
          ? 'Loading page…'
          : 'Solving captcha… (attempt ${p.attempt + 1}/$_maxAutoRetries)';
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(label, style: const TextStyle(color: Colors.black54)),
          ],
        ),
      );
    }

    if (p is _PhaseManualCaptcha) return _buildManualCaptcha(p);

    if (p is _PhaseResults) return _buildResults(p);

    if (p is _PhaseError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 52, color: Colors.red),
              const SizedBox(height: 12),
              Text(p.message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _loadForm,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  // ── Form ───────────────────────────────────────────────────────────────────

  Widget _buildForm(AdvancedSearchFormMeta meta) {
    final orgOpts = [
      const AdvSelectOption('0', 'All Organisations'),
      ...meta.orgOptions,
    ];
    final prodOpts = [
      const AdvSelectOption('0', 'All Categories'),
      ...meta.productCategoryOptions,
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        // ── Tender Details ──────────────────────────────────────────────────
        const _SectionHeader('Tender Details'),
        const SizedBox(height: 10),
        _DropdownField<String>(
          label: 'Tender Type',
          value: _tenderType,
          items: _tenderTypes
              .map((o) =>
                  DropdownMenuItem(value: o.value, child: Text(o.label)))
              .toList(),
          onChanged: (v) => setState(() => _tenderType = v ?? ''),
        ),
        const SizedBox(height: 12),
        _textField('Tender ID', _tenderIdCtrl),
        const SizedBox(height: 12),
        _textField('Tender Reference No', _tenderRefCtrl),
        const SizedBox(height: 12),
        _textField('Work / Item Title', _workTitleCtrl),
        const SizedBox(height: 12),
        _textField('Pincode', _pincodeCtrl,
            keyboardType: TextInputType.number),

        // ── Organisation ────────────────────────────────────────────────────
        const SizedBox(height: 20),
        const _SectionHeader('Organisation'),
        const SizedBox(height: 10),
        _DropdownField<String>(
          label: 'Organisation',
          value: orgOpts.any((o) => o.value == _organisation)
              ? _organisation
              : '0',
          items: orgOpts
              .map((o) => DropdownMenuItem(
                    value: o.value,
                    child:
                        Text(o.label, overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: _onOrgChanged,
        ),
        const SizedBox(height: 12),
        _CascadeDropdown(
          label: 'Department',
          value: _department,
          options: _deptOptions,
          loading: _loadingDept,
          parentLabel: 'organisation',
          onChanged: _onDeptChanged,
        ),
        const SizedBox(height: 12),
        _CascadeDropdown(
          label: 'Division',
          value: _division,
          options: _divOptions,
          loading: _loadingDiv,
          parentLabel: 'department',
          onChanged: _onDivChanged,
        ),
        const SizedBox(height: 12),
        _CascadeDropdown(
          label: 'Sub Division',
          value: _subDivision,
          options: _subDivOptions,
          loading: _loadingSubDiv,
          parentLabel: 'division',
          onChanged: _onSubDivChanged,
        ),
        const SizedBox(height: 12),
        _CascadeDropdown(
          label: 'Branch',
          value: _branch,
          options: _branchOptions,
          loading: _loadingBranch,
          parentLabel: 'sub division',
          onChanged: (v) => setState(() => _branch = v ?? ''),
        ),

        // ── Category ────────────────────────────────────────────────────────
        const SizedBox(height: 20),
        const _SectionHeader('Category'),
        const SizedBox(height: 10),
        _DropdownField<String>(
          label: 'Tender Category',
          value: _tenderCategory,
          items: _tenderCategories
              .map((o) =>
                  DropdownMenuItem(value: o.value, child: Text(o.label)))
              .toList(),
          onChanged: (v) => setState(() => _tenderCategory = v ?? ''),
        ),
        const SizedBox(height: 12),
        _DropdownField<String>(
          label: 'Product Category',
          value: prodOpts.any((o) => o.value == _productCategory)
              ? _productCategory
              : '0',
          items: prodOpts
              .map((o) => DropdownMenuItem(
                    value: o.value,
                    child:
                        Text(o.label, overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: (v) => setState(() => _productCategory = v ?? ''),
        ),
        const SizedBox(height: 12),
        _DropdownField<String>(
          label: 'Form of Contract',
          value: _formOfContract,
          items: _formsOfContract
              .map((o) =>
                  DropdownMenuItem(value: o.value, child: Text(o.label)))
              .toList(),
          onChanged: (v) => setState(() => _formOfContract = v ?? ''),
        ),

        // ── Financial ───────────────────────────────────────────────────────
        const SizedBox(height: 20),
        const _SectionHeader('Financial'),
        const SizedBox(height: 10),
        _DropdownField<String>(
          label: 'Payment Mode',
          value: _paymentMode,
          items: _paymentModes
              .map((o) =>
                  DropdownMenuItem(value: o.value, child: Text(o.label)))
              .toList(),
          onChanged: (v) => setState(() => _paymentMode = v ?? ''),
        ),
        const SizedBox(height: 12),
        _DropdownField<String>(
          label: 'Value Criteria',
          value: _valueCriteria,
          items: _valueCriterias
              .map((o) =>
                  DropdownMenuItem(value: o.value, child: Text(o.label)))
              .toList(),
          onChanged: (v) => setState(() {
            _valueCriteria = v ?? '0';
            if (_valueCriteria == '0') {
              _valueParameter = '0';
              _fromValueCtrl.clear();
              _toValueCtrl.clear();
            }
          }),
        ),
        if (_valueCriteria != '0') ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _DropdownField<String>(
                  label: 'Comparison',
                  value: _valueParameter,
                  items: _valueParameters
                      .map((o) => DropdownMenuItem(
                          value: o.value, child: Text(o.label)))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _valueParameter = v ?? '1'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                  child: _textField('Value', _fromValueCtrl,
                      keyboardType: TextInputType.number)),
              if (_valueParameter == '4') ...[  // Between
                const SizedBox(width: 10),
                Expanded(
                    child: _textField('To Value', _toValueCtrl,
                        keyboardType: TextInputType.number)),
              ],
            ],
          ),
        ],

        // ── Date ────────────────────────────────────────────────────────────
        const SizedBox(height: 20),
        const _SectionHeader('Date'),
        const SizedBox(height: 10),
        _DropdownField<String>(
          label: 'Date Criteria',
          value: _dateCriteria,
          items: _dateCriterias
              .map((o) =>
                  DropdownMenuItem(value: o.value, child: Text(o.label)))
              .toList(),
          onChanged: (v) => setState(() {
            _dateCriteria = v ?? '0';
            if (_dateCriteria == '0') {
              _fromDate = null;
              _toDate = null;
            }
          }),
        ),
        if (_dateCriteria != '0') ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                  child: _DateField(
                      label: 'From Date',
                      value: _fromDate,
                      onPicked: (d) => setState(() => _fromDate = d))),
              const SizedBox(width: 10),
              Expanded(
                  child: _DateField(
                      label: 'To Date',
                      value: _toDate,
                      onPicked: (d) => setState(() => _toDate = d))),
            ],
          ),
        ],

        // ── Options ──────────────────────────────────────────────────────────
        const SizedBox(height: 20),
        const _SectionHeader('Options'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            _CheckChip('Two Stage Bidding', _twoStage,
                (v) => setState(() => _twoStage = v)),
            _CheckChip('NDA Tenders', _nda,
                (v) => setState(() => _nda = v)),
            _CheckChip('Preferential Bidding', _preferential,
                (v) => setState(() => _preferential = v)),
            _CheckChip('GTE', _gte, (v) => setState(() => _gte = v)),
            _CheckChip(
                'ITE / TPS', _ite, (v) => setState(() => _ite = v)),
            _CheckChip('Tender Fee Exemption', _tenderFeeExemption,
                (v) => setState(() => _tenderFeeExemption = v)),
            _CheckChip('EMD Exemption', _emdExemption,
                (v) => setState(() => _emdExemption = v)),
          ],
        ),

        // ── Search button ────────────────────────────────────────────────────
        const SizedBox(height: 28),
        SizedBox(
          height: 48,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.indigo,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: _onSearch,
            icon: const Icon(Icons.search),
            label: const Text('Search Tenders',
                style: TextStyle(fontSize: 15)),
          ),
        ),
      ],
    );
  }

  Widget _textField(String label, TextEditingController ctrl,
      {TextInputType? keyboardType}) {
    return TextField(
      controller: ctrl,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }

  // ── Manual captcha ─────────────────────────────────────────────────────────

  Widget _buildManualCaptcha(_PhaseManualCaptcha p) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          elevation: 2,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Auto-solve failed. Please enter the captcha:',
                  style: TextStyle(fontSize: 13, color: Colors.black54),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    padding: const EdgeInsets.all(8),
                    child: Image.memory(p.captchaBytes,
                        scale: 0.5, filterQuality: FilterQuality.none),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _captchaCtrl,
                  autofocus: true,
                  textCapitalization: TextCapitalization.none,
                  decoration: InputDecoration(
                    labelText: 'Captcha text',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: _captchaCtrl.clear,
                    ),
                  ),
                  onSubmitted: (_) => _submitManual(),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.indigo,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: _submitManual,
                  child: const Text('Search'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Results list ───────────────────────────────────────────────────────────

  Future<void> _fetchPage(String url) async {
    setState(() => _phase = const _PhaseSolving(-1));
    try {
      final page = await _service.fetchPage(url);
      if (mounted) setState(() => _phase = _PhaseResults(page));
    } catch (e) {
      if (mounted) setState(() => _phase = _PhaseError(e.toString()));
    }
  }

  Widget _buildResults(_PhaseResults p) {
    if (p.page.results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off, size: 52, color: Colors.grey),
            const SizedBox(height: 12),
            const Text('No tenders found.',
                style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loadForm,
              icon: const Icon(Icons.tune),
              label: const Text('Modify Search'),
            ),
          ],
        ),
      );
    }

    final results = p.page.results;
    final pageInfo = p.page.pageInfo;

    return Column(
      children: [
        // ── Header bar ─────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            children: [
              const Icon(Icons.list_alt, size: 16, color: Colors.indigo),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  pageInfo.isNotEmpty
                      ? 'Records $pageInfo'
                      : '${results.length} result${results.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.indigo,
                      fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        // ── Result cards ───────────────────────────────────────────────────
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: results.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final result = results[i];
              return _ResultCard(
                result: result,
                onTap: () {
                  final url = result.links['View Tender Status'] ??
                      result.links.entries
                          .where((e) =>
                              e.value.contains('TenderStatus') ||
                              e.value.contains('TenderDetail') ||
                              e.value.contains('nicgep/app'))
                          .map((e) => e.value)
                          .firstOrNull ??
                      result.links.values.firstOrNull;
                  if (url == null) return;
                  final label = result.fields['Tender ID'] ??
                      result.links.keys.first;
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => _LinkDetailScreen(
                        label: label,
                        url: url,
                        service: _service,
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        // ── Pagination bar ─────────────────────────────────────────────────
        if (p.page.firstPageUrl != null ||
            p.page.prevPageUrl != null ||
            p.page.pageLinks.isNotEmpty ||
            p.page.nextPageUrl != null ||
            p.page.lastPageUrl != null)
          _PaginationBar(
            page: p.page,
            onFetch: _fetchPage,
          ),
      ],
    );
  }
}

// ── Result detail screen ───────────────────────────────────────────────────────

class AdvancedResultDetailScreen extends StatefulWidget {
  final TenderResult result;
  final AdvancedSearchService service;

  const AdvancedResultDetailScreen({
    super.key,
    required this.result,
    required this.service,
  });

  @override
  State<AdvancedResultDetailScreen> createState() =>
      _AdvancedResultDetailScreenState();
}

class _AdvancedResultDetailScreenState
    extends State<AdvancedResultDetailScreen> {
  _DetailPhase _phase = const _DetailPhaseLoading();

  @override
  void initState() {
    super.initState();
    _loadSummary();
  }

  Future<void> _loadSummary() async {
    setState(() => _phase = const _DetailPhaseLoading());

    // Try specific link names first, then any link URL that looks like a
    // detail page, then fall back to the first available link in the row.
    final viewUrl = widget.result.links['View Tender Status'] ??
        widget.result.links.entries
            .where((e) =>
                e.value.contains('TenderStatus') ||
                e.value.contains('TenderDetail') ||
                e.value.contains('nicgep/app'))
            .map((e) => e.value)
            .firstOrNull ??
        widget.result.links.values.firstOrNull ??
        '';

    if (viewUrl.isEmpty) {
      setState(() => _phase = const _DetailPhaseDone(sections: []));
      return;
    }

    try {
      final summary = await widget.service.fetchFullSummary(viewUrl);
      if (mounted) {
        setState(
            () => _phase = _DetailPhaseDone(sections: summary.sections));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _phase = _DetailPhaseError(e.toString()));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tenderId = widget.result.fields['Tender ID'] ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Text(tenderId.isNotEmpty ? tenderId : 'Tender Details',
            style: const TextStyle(fontSize: 14)),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          if (_phase is _DetailPhaseError || _phase is _DetailPhaseDone)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadSummary,
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: SelectionArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _ResultFieldsCard(result: widget.result),
              if (widget.result.links.isNotEmpty) ...[
                const SizedBox(height: 12),
                _LinksCard(
                  links: widget.result.links,
                  service: widget.service,
                ),
              ],
              const SizedBox(height: 12),
              _buildSummarySection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummarySection() {
    final p = _phase;

    if (p is _DetailPhaseLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(strokeWidth: 2),
              SizedBox(height: 12),
              Text('Fetching stage summary…',
                  style: TextStyle(color: Colors.black54)),
            ],
          ),
        ),
      );
    }

    if (p is _DetailPhaseError) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: Colors.red),
            const SizedBox(height: 10),
            Text(p.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _loadSummary,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (p is _DetailPhaseDone && p.sections.isNotEmpty) {
      return Column(
        children: p.sections
            .map((s) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _SummarySectionCard(section: s),
                ))
            .toList(),
      );
    }

    return const SizedBox.shrink();
  }
}

// ── Phase classes ──────────────────────────────────────────────────────────────

sealed class _Phase {
  const _Phase();
}

class _PhaseInit extends _Phase {
  const _PhaseInit();
}

class _PhaseForm extends _Phase {
  final AdvancedSearchFormMeta meta;
  const _PhaseForm(this.meta);
}

class _PhaseSolving extends _Phase {
  final int attempt;
  const _PhaseSolving(this.attempt);
}

class _PhaseManualCaptcha extends _Phase {
  final Uint8List captchaBytes;
  const _PhaseManualCaptcha(this.captchaBytes);
}

class _PhaseResults extends _Phase {
  final SearchPageResult page;
  const _PhaseResults(this.page);
}

class _PhaseError extends _Phase {
  final String message;
  const _PhaseError(this.message);
}

sealed class _DetailPhase {
  const _DetailPhase();
}

class _DetailPhaseLoading extends _DetailPhase {
  const _DetailPhaseLoading();
}

class _DetailPhaseDone extends _DetailPhase {
  final List<SummarySection> sections;
  const _DetailPhaseDone({required this.sections});
}

class _DetailPhaseError extends _DetailPhase {
  final String message;
  const _DetailPhaseError(this.message);
}

// ── Form widgets ───────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: Colors.indigo.shade400,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
            child: Divider(color: Colors.indigo.shade100, thickness: 1)),
      ],
    );
  }
}

class _DropdownField<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;

  const _DropdownField({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          isExpanded: true,
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// A dropdown that is disabled until the parent cascade level has been selected.
class _CascadeDropdown extends StatelessWidget {
  final String label;
  final String value;
  final List<AdvSelectOption>? options; // null = not yet loaded
  final bool loading;
  final String parentLabel;
  final ValueChanged<String?> onChanged;

  const _CascadeDropdown({
    required this.label,
    required this.value,
    required this.options,
    required this.loading,
    required this.parentLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Row(
        children: [
          Expanded(
            child: _DropdownField<String>(
              label: label,
              value: '',
              items: const [
                DropdownMenuItem(value: '', child: Text('Loading…'))
              ],
              onChanged: null,
            ),
          ),
          const SizedBox(width: 10),
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
      );
    }

    if (options == null) {
      // Not yet loaded — parent not selected
      return _DropdownField<String>(
        label: label,
        value: '',
        items: [
          DropdownMenuItem(
              value: '',
              child: Text('Select $parentLabel first',
                  style: const TextStyle(color: Colors.black38)))
        ],
        onChanged: null,
      );
    }

    if (options!.isEmpty) {
      return _DropdownField<String>(
        label: label,
        value: '',
        items: const [
          DropdownMenuItem(
              value: '',
              child: Text('N/A', style: TextStyle(color: Colors.black38)))
        ],
        onChanged: null,
      );
    }

    final all = [
      const AdvSelectOption('0', 'All'),
      ...options!,
    ];
    final safeValue = all.any((o) => o.value == value) ? value : '';
    return _DropdownField<String>(
      label: label,
      value: safeValue,
      items: all
          .map((o) => DropdownMenuItem(
                value: o.value,
                child: Text(o.label, overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      onChanged: onChanged,
    );
  }
}

class _DateField extends StatelessWidget {
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime> onPicked;

  const _DateField(
      {required this.label, required this.value, required this.onPicked});

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/'
      '${d.year}';

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final d = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2010),
          lastDate: DateTime(2030),
        );
        if (d != null) onPicked(d);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          suffixIcon: const Icon(Icons.calendar_today, size: 16),
        ),
        child: Text(
          value != null ? _fmt(value!) : 'Select…',
          style: TextStyle(
            fontSize: 14,
            color: value != null ? Colors.black87 : Colors.black38,
          ),
        ),
      ),
    );
  }
}

class _CheckChip extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _CheckChip(this.label, this.value, this.onChanged);

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: value,
      onSelected: onChanged,
      selectedColor: Colors.indigo.shade100,
      checkmarkColor: Colors.indigo,
      labelPadding: const EdgeInsets.symmetric(horizontal: 2),
    );
  }
}

// ── Pagination bar ─────────────────────────────────────────────────────────────

class _PaginationBar extends StatelessWidget {
  final SearchPageResult page;
  final void Function(String url) onFetch;

  const _PaginationBar({required this.page, required this.onFetch});

  Widget _navBtn({
    required IconData icon,
    required String? url,
    String? tooltip,
  }) {
    return IconButton(
      icon: Icon(icon, size: 20),
      onPressed: url != null ? () => onFetch(url) : null,
      tooltip: tooltip,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      constraints: const BoxConstraints(minWidth: 32),
      color: Colors.indigo,
      disabledColor: Colors.grey.shade300,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            _navBtn(
              icon: Icons.first_page,
              url: page.firstPageUrl,
              tooltip: 'First page',
            ),
            _navBtn(
              icon: Icons.chevron_left,
              url: page.prevPageUrl,
              tooltip: 'Previous page',
            ),
            ...page.pageLinks.map((e) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: SizedBox(
                    height: 32,
                    child: OutlinedButton(
                      onPressed: () => onFetch(e.value),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: Size.zero,
                        side: BorderSide(color: Colors.indigo.shade200),
                        foregroundColor: Colors.indigo,
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                      child: Text(e.key),
                    ),
                  ),
                )),
            _navBtn(
              icon: Icons.chevron_right,
              url: page.nextPageUrl,
              tooltip: 'Next page',
            ),
            _navBtn(
              icon: Icons.last_page,
              url: page.lastPageUrl,
              tooltip: 'Last page',
            ),
          ],
        ),
      ),
    );
  }
}

// ── Result display widgets ─────────────────────────────────────────────────────

class _ResultCard extends StatelessWidget {
  final TenderResult result;
  final VoidCallback onTap;

  const _ResultCard({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tenderId = result.fields['Tender ID'] ?? '';
    final stage = result.fields['Tender Stage'] ??
        result.fields['Stage'] ??
        '';

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header row: Tender ID + Stage chip ─────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.confirmation_number_outlined,
                      size: 14, color: Colors.indigo),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      tenderId.isNotEmpty ? tenderId : '—',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.indigo),
                    ),
                  ),
                  if (stage.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.indigo.shade50,
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: Colors.indigo.shade200),
                      ),
                      child: Text(stage,
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.indigo.shade700)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // ── All fields ─────────────────────────────────────────────
              ...result.allFields
                  .where((e) =>
                      e.key != 'Tender ID' &&
                      e.key != 'Tender Stage' &&
                      e.key != 'Stage' &&
                      e.value.isNotEmpty)
                  .map((e) => Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 112,
                              child: Text(e.key,
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.grey.shade600)),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(e.value,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.black87)),
                            ),
                          ],
                        ),
                      )),
              const SizedBox(height: 6),
              const Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('View Details',
                        style: TextStyle(
                            fontSize: 12, color: Colors.indigo)),
                    Icon(Icons.chevron_right,
                        size: 16, color: Colors.indigo),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultFieldsCard extends StatelessWidget {
  final TenderResult result;
  const _ResultFieldsCard({required this.result});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: Colors.indigo,
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: const Text('Tender Details',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: result.allFields
                  .map((e) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 130,
                              child: Text(e.key,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.indigo)),
                            ),
                            Expanded(
                              child: Text(e.value,
                                  style: const TextStyle(fontSize: 13)),
                            ),
                          ],
                        ),
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummarySectionCard extends StatelessWidget {
  final SummarySection section;
  const _SummarySectionCard({required this.section});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (section.title.isNotEmpty)
            Container(
              color: Colors.indigo,
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Text(section.title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13)),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: section.isKeyValue
                ? _buildKeyValue()
                : section.isKeyValueLike
                    ? _buildKeyValueLike()
                    : _buildTable(),
          ),
        ],
      ),
    );
  }

  Widget _kvRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.indigo)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 12, color: Colors.black87)),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyValue() {
    return Column(
      children: section.rows
          .map((row) => _kvRow(row[0], row.length > 1 ? row[1] : ''))
          .toList(),
    );
  }

  /// Renders 4-column (label,value,label,value) and mixed 2/4-col tables
  /// as a clean key-value list.
  Widget _buildKeyValueLike() {
    final widgets = <Widget>[];
    for (final row in section.rows) {
      if (row.length == 4) {
        final l1 = row[0]; final v1 = row[1];
        final l2 = row[2]; final v2 = row[3];
        if (l1.isNotEmpty || v1.isNotEmpty) widgets.add(_kvRow(l1, v1));
        if (l2.isNotEmpty || v2.isNotEmpty) widgets.add(_kvRow(l2, v2));
      } else if (row.length == 2) {
        widgets.add(_kvRow(row[0], row[1]));
      } else if (row.length == 1 && row[0].isNotEmpty) {
        // Sub-header row
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(row[0],
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.indigo.shade300)),
        ));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  Widget _cellWidget(String text, String? url) {
    if (url != null && url.isNotEmpty) {
      return GestureDetector(
        onTap: () => launchUrl(Uri.parse(url),
            mode: LaunchMode.externalApplication),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12,
                color: Colors.teal,
                decoration: TextDecoration.underline)),
      );
    }
    return Text(text,
        style: const TextStyle(fontSize: 12, color: Colors.black87));
  }

  Widget _buildTable() {
    final headers = section.headers;
    final dataRows = section.dataRows;
    final dataLinks = section.dataRowLinks;
    if (headers.isEmpty) return const SizedBox.shrink();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: Colors.grey.shade200, width: 1),
        children: [
          TableRow(
            decoration: BoxDecoration(
                color: Colors.indigo.withValues(alpha: 0.08)),
            children: headers
                .map((h) => Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      child: Text(h,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.indigo)),
                    ))
                .toList(),
          ),
          ...List.generate(dataRows.length, (ri) {
            final row = dataRows[ri];
            final links = ri < dataLinks.length ? dataLinks[ri] : <String?>[];
            final padded = List.generate(
                headers.length, (i) => i < row.length ? row[i] : '');
            final paddedLinks = List.generate(
                headers.length,
                (i) => i < links.length ? links[i] : null);
            return TableRow(
              children: List.generate(
                headers.length,
                (i) => Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  child: _cellWidget(padded[i], paddedLinks[i]),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ── Links card ────────────────────────────────────────────────────────────────

class _LinksCard extends StatelessWidget {
  final Map<String, String> links;
  final AdvancedSearchService service;

  const _LinksCard({required this.links, required this.service});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: Colors.teal,
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: const Text('Links',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
          ),
          ...links.entries.map((e) => InkWell(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _LinkDetailScreen(
                      label: e.key,
                      url: e.value,
                      service: service,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.open_in_new,
                          size: 14, color: Colors.teal),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(e.key,
                            style: const TextStyle(
                                fontSize: 13, color: Colors.teal)),
                      ),
                      const Icon(Icons.chevron_right,
                          size: 16, color: Colors.grey),
                    ],
                  ),
                ),
              )),
        ],
      ),
    );
  }
}

// ── Link detail screen ────────────────────────────────────────────────────────

class _LinkDetailScreen extends StatefulWidget {
  final String label;
  final String url;
  final AdvancedSearchService service;

  const _LinkDetailScreen({
    required this.label,
    required this.url,
    required this.service,
  });

  @override
  State<_LinkDetailScreen> createState() => _LinkDetailScreenState();
}

class _LinkDetailScreenState extends State<_LinkDetailScreen> {
  bool _loading = true;
  String? _error;
  List<SummarySection> _sections = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.service.fetchFullSummary(widget.url);
      if (mounted) setState(() { _sections = result.sections; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.label, style: const TextStyle(fontSize: 14)),
        backgroundColor: Colors.teal,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: SelectionArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline,
                                size: 40, color: Colors.red),
                            const SizedBox(height: 10),
                            Text(_error!,
                                textAlign: TextAlign.center,
                                style:
                                    const TextStyle(color: Colors.black54)),
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              onPressed: _load,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Retry'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : _sections.isEmpty
                      ? const Center(
                          child: Text('No content found.',
                              style: TextStyle(color: Colors.black54)))
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: _sections.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 12),
                          itemBuilder: (_, i) =>
                              _SummarySectionCard(section: _sections[i]),
                        ),
        ),
      ),
    );
  }
}
