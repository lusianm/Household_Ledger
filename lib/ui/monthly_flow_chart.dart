import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'common.dart';

/// Both series and every month share one zero baseline and one scale.
class MonthlyFlowChart extends StatelessWidget {
  final List<({int month, int income, int expense})> data;
  const MonthlyFlowChart(this.data, {super.key});

  @override
  Widget build(BuildContext context) {
    final values = data.expand((e) => [e.income, e.expense]);
    final high = values.fold<int>(0, math.max);
    final low = values.fold<int>(0, math.min);
    final span = math.max(1, high - low);
    const incomeColor = Color(0xff0087a8);
    const expenseColor = Color(0xffd27a24);
    Widget series(String label, int value, Color color) => Semantics(
      label: '$label ${money(value)}',
      child: ExcludeSemantics(
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: Text(label, style: const TextStyle(fontSize: 12)),
            ),
            Expanded(
              child: SizedBox(
                height: 18,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final zero = -low / span * constraints.maxWidth;
                    final length = value.abs() / span * constraints.maxWidth;
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                        if (value != 0)
                          Positioned(
                            left: value < 0 ? zero - length : zero,
                            width: length,
                            top: 2,
                            bottom: 2,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: color,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        Positioned(
                          left: zero.clamp(
                            0,
                            math.max(0, constraints.maxWidth - 1),
                          ),
                          top: 0,
                          bottom: 0,
                          width: 1,
                          child: ColoredBox(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 104,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  money(value),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '수입과 지출을 같은 눈금으로 비교합니다. 금액은 환불을 반영한 실제 기록입니다.',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 12),
        for (final row in data)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 36,
                  child: Text(
                    '${row.month}월',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Expanded(
                  child: Column(
                    children: [
                      series('수입', row.income, incomeColor),
                      const SizedBox(height: 8),
                      series('지출', row.expense, expenseColor),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (low < 0)
          const Text(
            '음수는 0선 왼쪽에 표시됩니다. 지출보다 환불이 크면 지출이 음수가 됩니다.',
            style: TextStyle(fontSize: 12),
          ),
      ],
    );
  }
}
