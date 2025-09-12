// EPG Schedule View, WIP
import 'package:flutter/material.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/sxi_layer.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/data/handlers/program_guide_handler.dart';

class EpgScheduleView extends StatefulWidget {
  final SXiLayer sxiLayer;
  const EpgScheduleView({super.key, required this.sxiLayer});

  @override
  State<EpgScheduleView> createState() => _EpgScheduleViewState();
}

class _EpgScheduleViewState extends State<EpgScheduleView>
    with SingleTickerProviderStateMixin {
  List<EpgPoolView> _pools = const <EpgPoolView>[];
  late final TabController _tabController;
  int _selectedDay = 0;
  final ScrollController _hScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _refresh();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _hScrollController.dispose();
    super.dispose();
  }

  void _refresh() {
    final handler = widget.sxiLayer.sdtpProcessor
        .dsiHandlers[DataServiceIdentifier.electronicProgramGuide.value];
    if (handler is ProgramGuideHandler) {
      setState(() {
        _pools = handler.getAllPoolsSnapshot();
      });
    } else {
      setState(() {
        _pools = const <EpgPoolView>[];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EPG Schedule'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          )
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Guide'),
            Tab(text: 'Details'),
          ],
        ),
      ),
      body: _pools.isEmpty
          ? const Center(child: Text('No schedule extracted yet'))
          : TabBarView(
              controller: _tabController,
              children: [
                _buildGuideTab(context),
                _buildDetailsTab(context),
              ],
            ),
    );
  }

  Widget _buildGuideTab(BuildContext context) {
    // Use current pool if available, otherwise fall back to first pool
    final EpgPoolView pool = _pools.firstWhere((p) => p.isCurrent,
        orElse: () => _pools.isNotEmpty ? _pools.first : (null as dynamic));

    final int days = pool.segments.length;
    if (_selectedDay >= days) _selectedDay = 0;

    // Collect SIDs present on selected day
    final seg = pool.segments[_selectedDay];
    final List<int> sids = seg.events.map((e) => e.sid).toSet().toList()
      ..sort();

    // Build a simple horizontal timeline where 1 minute = 2 px
    const double pxPerMinute = 2.0;
    const double rowHeight = 48.0;
    final double contentWidth = 24 * 60 * pxPerMinute; // 24h

    return Column(
      children: [
        SizedBox(
          height: 48,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: days,
            itemBuilder: (context, idx) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: ChoiceChip(
                  label: Text('Day $idx'),
                  selected: _selectedDay == idx,
                  onSelected: (v) {
                    if (!v) return;
                    setState(() => _selectedDay = idx);
                  },
                ),
              );
            },
          ),
        ),
        Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              SizedBox(
                width: 100,
                child: ListView.builder(
                  itemCount: sids.length,
                  itemBuilder: (context, i) {
                    return Container(
                      alignment: Alignment.centerLeft,
                      height: rowHeight,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text('SID ${sids[i]}',
                          style: Theme.of(context).textTheme.bodyMedium),
                    );
                  },
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Scrollbar(
                  controller: _hScrollController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _hScrollController,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: contentWidth,
                      child: ListView.builder(
                        itemCount: sids.length,
                        itemBuilder: (context, i) {
                          final int sid = sids[i];
                          final events = seg.events
                              .where((e) => e.sid == sid)
                              .toList()
                            ..sort((a, b) =>
                                a.startSeconds.compareTo(b.startSeconds));
                          return SizedBox(
                            height: rowHeight,
                            child: Stack(
                              children: [
                                for (final ev in events)
                                  Positioned(
                                    left:
                                        (ev.startSeconds / 60.0) * pxPerMinute,
                                    width: (ev.durationSeconds / 60.0) *
                                        pxPerMinute,
                                    top: 4,
                                    bottom: 4,
                                    child: Tooltip(
                                      message:
                                          '${ev.title ?? 'Program'}\n${_fmtHms(ev.startSeconds)} · ${_fmtMm(ev.durationSeconds)}',
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: Colors.blueGrey.shade300,
                                          borderRadius: const BorderRadius.all(
                                              Radius.circular(6)),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 6),
                                        child: Text(
                                          (ev.title?.isNotEmpty == true
                                              ? ev.title!
                                              : 'SID $sid'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDetailsTab(BuildContext context) {
    return ListView.builder(
      itemCount: _pools.length,
      itemBuilder: (context, index) {
        final pool = _pools[index];
        final int readySegments = pool.segments.where((s) {
          final bool gridOk = s.gridTotal == 0 || s.gridReceived == s.gridTotal;
          final bool textOk = s.textTotal == 0 || s.textReceived == s.textTotal;
          return s.gridReceived > 0 && s.textReceived > 0 && gridOk && textOk;
        }).length;
        return ExpansionTile(
          title: Text(
              'Epoch ${pool.epoch} ${pool.isCurrent ? '(current)' : '(candidate)'}'),
          subtitle:
              Text('$readySegments/${pool.segments.length} segments ready'),
          children: [
            for (final seg in pool.segments)
              ExpansionTile(
                title: Text('Segment ${seg.segmentIndex}'),
                subtitle: Text(
                    '${seg.events.length} programs · strings ${seg.stringTableSize} · ${_pct(seg.gridReceived, seg.gridTotal)} grid · ${_pct(seg.textReceived, seg.textTotal)} text'),
                children: [
                  if ((seg.gridIndices != null &&
                          seg.gridIndices!.isNotEmpty) ||
                      (seg.textIndices != null && seg.textIndices!.isNotEmpty))
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextButton(
                              onPressed: () {
                                logger
                                    .t('EPG: String Table: ${seg.stringTable}');
                              },
                              child: Text('Log String Table')),
                          Text(
                            'Grid AUs: ${seg.gridReceived}/${seg.gridTotal}'
                            '${seg.gridBytes != null ? '  (${seg.gridBytes} bytes)' : ''}'
                            '${seg.gridIndices != null ? '  idx ${seg.gridIndices}' : ''}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Text(
                            'Text AUs: ${seg.textReceived}/${seg.textTotal}'
                            '${seg.textBytes != null ? '  (${seg.textBytes} bytes)' : ''}'
                            '${seg.textIndices != null ? '  idx ${seg.textIndices}' : ''}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  for (final ev in seg.events)
                    ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 12,
                        child: Text(
                          (ev.sid % 100).toString(),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      title: Text(
                        '${ev.title?.isNotEmpty == true ? ev.title! : 'SID ${ev.sid}'}  ${_fmtHms(ev.startSeconds)}',
                      ),
                      subtitle: Text(
                        '${ev.subtitle?.isNotEmpty == true ? '${ev.subtitle!} · ' : ''}Duration ${_fmtMm(ev.durationSeconds)}  Flags 0x${ev.flags.toRadixString(16)}',
                      ),
                      trailing: ev.topics.isEmpty
                          ? null
                          : Tooltip(
                              message: 'Topics: ${ev.topics.join(', ')}',
                              child: const Icon(Icons.info_outline),
                            ),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }

  String _fmtHms(int seconds) {
    if (seconds < 0) seconds = 0;
    final int h = seconds ~/ 3600;
    final int m = (seconds % 3600) ~/ 60;
    final int s = seconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(h)}:${two(m)}:${two(s)}';
  }

  String _fmtMm(int seconds) {
    final int m = (seconds / 60).round();
    return '${m}m';
  }

  String _pct(int have, int total) {
    if (total <= 0) return '0%';
    final int p = ((have * 100) / total).clamp(0, 100).round();
    return '$p%';
  }
}

class EpgScheduleDialog {
  static Future<void> show(BuildContext context, SXiLayer sxiLayer) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => EpgScheduleView(sxiLayer: sxiLayer)),
    );
  }
}
