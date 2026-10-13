import 'ledger_service.dart';
import 'value.dart';

/// A group owns references, never cash postings or a manually entered total.
extension SettlementService on LedgerService {
  void saveSettlement(Json group) {
    checkDate(group['date'] as String);
    store.save('settlement_group', group);
  }

  void setClaimReceived(String groupId, String claimId, bool received) {
    final group = store.get('settlement_group', groupId)!;
    require(group['closed'] != true, '정산을 다시 연 뒤 수정해 주세요.');
    final claims = rows(group['claims']);
    final claim = claims.singleWhere((c) => c['id'] == claimId);
    require(claim['debt'] == null, '빚 관리에서 처리해 주세요.');
    claim['received'] = received;
    group['claims'] = claims;
    saveSettlement(group);
  }

  String transferClaimToDebt(String groupId, String claimId) {
    final group = store.get('settlement_group', groupId)!;
    require(group['closed'] != true, '정산을 다시 연 뒤 수정해 주세요.');
    final claims = rows(group['claims']);
    final claim = claims.singleWhere((c) => c['id'] == claimId);
    require(
      claim['received'] != true && claim['debt'] == null,
      '이미 받았거나 빚으로 옮긴 항목입니다.',
    );
    // Stable identity also prevents duplicate debts from concurrent devices.
    final id = stableId('${store.ledgerId}/settlement/$groupId/${claim['id']}');
    require(store.get('debt', id) == null, '이미 빚으로 옮긴 항목입니다. 동기화 상태를 확인해 주세요.');
    claim['debt'] = id;
    group['claims'] = claims;
    store.saveBatch([
      ('settlement_group', group),
      (
        'debt',
        {
          'id': id,
          'person': claim['person'],
          'direction': 'lent',
          'date': group['date'],
          'due': null,
          'memo': '${group['name']} · ${claim['memo']}',
          'events': [
            {
              'id': stableId('$id/principal'),
              'type': 'add',
              'amount': claim['amount'],
              'date': group['date'],
              'account': null,
            },
          ],
        },
      ),
    ]);
    return id;
  }
}
