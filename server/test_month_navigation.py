import copy
import unittest
from unittest.mock import patch

import ledger as L


class MonthNavigationTests(unittest.TestCase):
    def setUp(self):
        clock = patch('ledger.now', return_value='2026-10-21T12:00:00+09:00')
        clock.start()
        self.addCleanup(clock.stop)
        self.s = L.new_household('월 이동 검사', '본인', 'separate')
        self.a = self.s['members'][0]['id']
        self.b = L.add_member(self.s, '상대')['id']

    def entry(self, day, actor=None, **overrides):
        values = dict(amount=1000, note='검증용 내역', day=day, scope='shared')
        values.update(overrides)
        return L.add_entry(self.s, actor or self.a, values)

    def schedule(self, **overrides):
        values = dict(note='검증용 일정', amount=1000, scope='shared',
                      category=self.s['categories'][0]['id'], payer=self.a,
                      funding='personal', startDay='2026-10-01', dayOfMonth=31)
        values.update(overrides)
        return L.add_recurring(self.s, self.a, values)

    def assert_navigation(self, month, previous=None, next=None, actor=None):
        view = L.snapshot(self.s, actor or self.a, month)
        self.assertEqual(view.get('monthNavigation'), dict(previous=previous, next=next))
        return view

    def test_empty_current_month_is_usable_and_other_empty_months_are_skipped(self):
        self.assert_navigation('2026-10')
        self.assert_navigation('2026-06', next='2026-10')
        self.assert_navigation('2027-02', previous='2026-10')

    def test_recorded_months_skip_gaps_in_both_directions_even_if_net_zero(self):
        self.entry('2026-02-05')
        self.entry('2027-01-03')
        self.entry('2027-01-03', kind='refund')
        self.assert_navigation('2026-10', '2026-02', '2027-01')
        self.assert_navigation('2026-02', next='2026-10')
        self.assert_navigation('2027-01', previous='2026-10')

    def test_private_and_deleted_records_do_not_reveal_month_existence(self):
        self.entry('2026-02-01', scope='personal')
        self.entry('2027-03-01', actor=self.b, scope='personal')
        deleted = self.entry('2028-04-01')
        L.update_entry(self.s, self.a, deleted['id'], {'voided': True})
        self.assert_navigation('2026-10', previous='2026-02')
        self.assert_navigation('2026-10', next='2027-03', actor=self.b)

    def test_deposit_month_is_navigable_without_expense(self):
        self.s['mode'] = 'pool'
        self.entry('2026-06-01', kind='deposit', funding='fund')
        self.assert_navigation('2026-10', previous='2026-06')

    def test_recurring_start_after_due_day_skips_first_empty_month(self):
        self.schedule(startDay='2027-01-20', dayOfMonth=10)
        self.assert_navigation('2026-10', next='2027-02')
        self.assert_navigation('2027-01', previous='2026-10', next='2027-02')
        self.assert_navigation('2027-02', previous='2026-10', next='2027-03')
        self.assert_navigation('2027-03', previous='2027-02', next='2027-04')

    def test_recurring_clamps_end_of_month_and_handles_year_boundary(self):
        self.schedule(startDay='2028-02-29')
        self.assert_navigation('2027-12', previous='2026-10', next='2028-02')
        view = self.assert_navigation('2028-02', previous='2026-10', next='2028-03')
        self.assertEqual(view['recurringPayments'][0]['dueDay'], '2028-02-29')
        self.assertEqual(view['stats']['total'], 0, 'Plans must never become actual spending')

    def test_paused_deleted_and_partner_private_recurring_do_not_open_months(self):
        private = self.schedule(scope='personal', startDay='2027-04-01')
        self.schedule(active=False, startDay='2027-02-01')
        deleted = self.schedule(startDay='2027-03-01')
        L.delete_recurring(self.s, self.a, deleted['id'])
        self.assert_navigation('2026-10', next='2027-04')
        self.assert_navigation('2026-10', actor=self.b)
        L.update_recurring(self.s, self.a, private['id'], dict(scope='shared'))
        self.assert_navigation('2026-10', next='2027-04', actor=self.b)

    def test_recorded_recurring_month_survives_pause_without_opening_future_months(self):
        recurring = self.schedule(startDay='2026-08-01')
        self.entry('2026-08-31', recurringID=recurring['id'], recurringMonth='2026-08',
                   payer=self.a, funding='personal', category=recurring['category'])
        L.update_recurring(self.s, self.a, recurring['id'], dict(active=False))
        self.assert_navigation('2026-10', previous='2026-08')

    def test_current_month_uses_korean_time_and_metadata_read_does_not_write(self):
        before = copy.deepcopy(self.s)
        with patch('ledger.now', return_value='2026-10-31T16:00:00+00:00'):
            self.assert_navigation('2026-10', next='2026-11')
            self.assert_navigation('2026-11')
        self.assertEqual(self.s, before)

    def test_last_supported_month_does_not_overflow_when_no_future_occurrence_exists(self):
        self.schedule(startDay='9999-12-20', dayOfMonth=10)
        self.assert_navigation('9999-11', previous='2026-10')
        self.assert_navigation('9999-12', previous='2026-10')
