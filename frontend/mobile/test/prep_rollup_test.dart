import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:suar_mobile/content/doc_models.dart';

void main() {
  // Pack (section w3, usePercent)
  //   FAK (section w3)          path 0.0
  //     a (check w2)            path 0.0.0
  //     b (check w1)            path 0.0.1
  //   tool (check w1)           path 0.1
  // Tips (section w1)           path 1   -> only a guide child => excluded from %
  //   Flood (guide)            path 1.0
  final nodes = <DocNode>[
    const DocNode(title: 'Pack', kind: 'section', weight: 3, usePercent: true, children: [
      DocNode(title: 'FAK', kind: 'section', weight: 3, children: [
        DocNode(title: 'a', kind: 'check', weight: 2),
        DocNode(title: 'b', kind: 'check', weight: 1),
      ]),
      DocNode(title: 'tool', kind: 'check', weight: 1),
    ]),
    const DocNode(title: 'Tips', kind: 'section', weight: 1, children: [
      DocNode(title: 'Flood', kind: 'guide'),
    ]),
  ];

  test('overall % = weighted roll-up; guides excluded', () {
    expect(DocRollup(const {}).overallPercent(nodes), 0);
    // a done: FAK = (2*1+1*0)/3 = .667; Pack = (3*.667 + 1*0)/4 = .5; Tips excluded
    expect(DocRollup({'0.0.0'}).overallPercent(nodes), closeTo(50, 0.01));
    // a+b+tool done: FAK=1, Pack=(3*1+1*1)/4=1 -> 100
    expect(DocRollup({'0.0.0', '0.0.1', '0.1'}).overallPercent(nodes), closeTo(100, 0.01));
  });

  test('nodePercent + counts', () {
    final r = DocRollup({'0.0.0'});
    expect(r.nodePercent(nodes[0], '0'), closeTo(50, 0.01));
    expect(r.nodePercent(nodes[0].children[0], '0.0'), closeTo(66.666, 0.01));
    expect(r.counts(nodes[1], '1'), false); // section with only a guide
    expect(r.counts(nodes[0], '0'), true);
  });

  test('incompleteTitles skips done + guides, labelled by top section', () {
    expect(DocRollup({'0.0.0'}).incompleteTitles(nodes, 5), ['Pack › b', 'Pack › tool']);
  });

  test('Doc parses structure JSON incl. guide pages + blocks', () {
    final structure = jsonEncode({
      'usePercent': true,
      'percentText': 'You are {p}% ready',
      'nodes': [
        {
          'title': 'Basic First Aid',
          'kind': 'section',
          'children': [
            {
              'title': 'Bleeding',
              'kind': 'guide',
              'layout': 'steps',
              'pages': [
                {
                  'title': 'Press',
                  'subtitle': 'firmly',
                  'blocks': [
                    {'type': 'paragraph', 'runs': [{'text': 'hi', 'bold': true}]},
                    {'type': 'whoknows'},
                  ],
                }
              ],
            }
          ],
        }
      ],
    });
    final doc = Doc.fromRow(
        docId: 'd1', category: 'first_aid', title: 'T', version: 1, updatedAt: '', structure: structure);
    expect(doc.usePercent, true);
    expect(doc.percentText.replaceAll('{p}', '42'), 'You are 42% ready');
    final guide = doc.nodes[0].children[0];
    expect(guide.isGuide, true);
    expect(guide.pages.first.subtitle, 'firmly');
    expect(guide.pages.first.blocks.length, 2); // unknown block tolerated, not dropped
  });
}
