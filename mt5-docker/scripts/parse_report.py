#!/usr/bin/env python3
"""Parse MT5 Strategy Tester HTML reports into text/JSON/CSV."""

import sys
import json
import csv
import re
import io
from html.parser import HTMLParser


class MT5ReportParser(HTMLParser):
    """State-machine parser for MT5 backtest HTML reports."""

    def __init__(self):
        super().__init__()
        self.tables = []       # list of tables, each is list of rows
        self._current_table = None
        self._current_row = None
        self._current_cell = None
        self._in_cell = False
        self._cell_colspan = 1
        self._in_bold = False
        self._depth = 0

    def handle_starttag(self, tag, attrs):
        attrs_dict = dict(attrs)
        if tag == 'table':
            self._current_table = []
            self._depth = 0
        elif tag == 'tr' and self._current_table is not None:
            self._current_row = []
        elif tag in ('td', 'th') and self._current_row is not None:
            self._in_cell = True
            self._current_cell = ''
            self._cell_colspan = int(attrs_dict.get('colspan', '1'))
        elif tag == 'b':
            self._in_bold = True

    def handle_endtag(self, tag):
        if tag in ('td', 'th') and self._in_cell:
            self._in_cell = False
            text = self._current_cell.strip()
            self._current_row.append(text)
            # Pad with empty strings for colspan
            for _ in range(self._cell_colspan - 1):
                self._current_row.append('')
            self._current_cell = None
        elif tag == 'tr' and self._current_row is not None:
            if self._current_row:  # skip empty rows
                self._current_table.append(self._current_row)
            self._current_row = None
        elif tag == 'table' and self._current_table is not None:
            self.tables.append(self._current_table)
            self._current_table = None
        elif tag == 'b':
            self._in_bold = False

    def handle_data(self, data):
        if self._in_cell and self._current_cell is not None:
            self._current_cell += data


def clean_number(s):
    """Convert MT5 number format to float: '2 949.00' -> 2949.0"""
    if not s:
        return 0.0
    # Remove non-breaking spaces and regular spaces in numbers
    s = s.replace('\xa0', '').replace(' ', '')
    # Extract the first number (handles "918.60(29.34%)" format)
    m = re.match(r'(-?[\d.]+)', s)
    return float(m.group(1)) if m else 0.0


def extract_pct(s):
    """Extract percentage from strings like '33 (60.61%)' or '29.34% (918.60)'."""
    if not s:
        return None
    m = re.search(r'([\d.]+)%', s)
    return float(m.group(1)) if m else None


def find_metric(rows, label):
    """Find the value cell after a label cell in Table 1 rows, skipping colspan padding."""
    for row in rows:
        for i, cell in enumerate(row):
            if cell.rstrip().rstrip(':') == label.rstrip().rstrip(':') or cell.strip() == label.strip():
                # Skip empty colspan padding cells to find the actual value
                for j in range(i + 1, len(row)):
                    if row[j].strip():
                        return row[j]
    return None


def parse_report(filepath):
    """Parse an MT5 HTML report file and return structured data."""
    # Handle UTF-16LE encoding (MT5 default) or UTF-8
    with open(filepath, 'rb') as f:
        raw = f.read()

    for encoding in ('utf-16', 'utf-16-le', 'utf-8', 'latin-1'):
        try:
            html = raw.decode(encoding)
            break
        except (UnicodeDecodeError, UnicodeError):
            continue
    else:
        html = raw.decode('utf-8', errors='ignore')

    parser = MT5ReportParser()
    parser.feed(html)

    if len(parser.tables) < 2:
        print(f"ERROR: Expected 2 tables, found {len(parser.tables)}", file=sys.stderr)
        sys.exit(1)

    t1_rows = parser.tables[0]  # Settings + Results
    t2_rows = parser.tables[1]  # Orders + Deals

    # --- Extract settings ---
    settings = {}
    setting_labels = ('Expert', 'Symbol', 'Period', 'Company', 'Currency',
                      'Initial Deposit', 'Leverage')
    for label in setting_labels:
        val = find_metric(t1_rows, label + ':')
        if val:
            settings[label.lower().replace(' ', '_')] = val

    # --- Extract summary metrics ---
    metrics = {}

    def get_metric(label, as_float=True):
        val = find_metric(t1_rows, label)
        if val is None:
            return 0.0 if as_float else '0'
        return clean_number(val) if as_float else val.strip()

    metrics['total_net_profit'] = get_metric('Total Net Profit:')
    metrics['gross_profit'] = get_metric('Gross Profit:')
    metrics['gross_loss'] = get_metric('Gross Loss:')
    metrics['profit_factor'] = get_metric('Profit Factor:')
    metrics['expected_payoff'] = get_metric('Expected Payoff:')
    metrics['recovery_factor'] = get_metric('Recovery Factor:')
    metrics['sharpe_ratio'] = get_metric('Sharpe Ratio:')
    metrics['margin_level'] = get_metric('Margin Level:', as_float=False)
    metrics['total_trades'] = int(get_metric('Total Trades:'))
    metrics['total_deals'] = int(get_metric('Total Deals:'))

    # Drawdowns (contain both value and percentage)
    dd_max_bal = get_metric('Balance Drawdown Maximal:', as_float=False)
    dd_max_eq = get_metric('Equity Drawdown Maximal:', as_float=False)
    dd_abs_bal = get_metric('Balance Drawdown Absolute:')
    dd_abs_eq = get_metric('Equity Drawdown Absolute:')

    metrics['balance_dd_absolute'] = dd_abs_bal
    metrics['equity_dd_absolute'] = dd_abs_eq
    metrics['balance_dd_maximal'] = clean_number(dd_max_bal)
    metrics['balance_dd_maximal_pct'] = extract_pct(dd_max_bal)
    metrics['equity_dd_maximal'] = clean_number(dd_max_eq)
    metrics['equity_dd_maximal_pct'] = extract_pct(dd_max_eq)

    # Trade breakdown
    short_raw = get_metric('Short Trades (won %):', as_float=False)
    long_raw = get_metric('Long Trades (won %):', as_float=False)
    profit_raw = get_metric('Profit Trades (% of total):', as_float=False)
    loss_raw = get_metric('Loss Trades (% of total):', as_float=False)

    metrics['short_trades'] = int(clean_number(short_raw))
    metrics['short_win_pct'] = extract_pct(short_raw)
    metrics['long_trades'] = int(clean_number(long_raw))
    metrics['long_win_pct'] = extract_pct(long_raw)
    metrics['profit_trades'] = int(clean_number(profit_raw))
    metrics['profit_trades_pct'] = extract_pct(profit_raw)
    metrics['loss_trades'] = int(clean_number(loss_raw))
    metrics['loss_trades_pct'] = extract_pct(loss_raw)

    # Additional metrics
    metrics['largest_profit_trade'] = get_metric('Largest profit trade:')
    metrics['largest_loss_trade'] = get_metric('Largest loss trade:')
    metrics['average_profit_trade'] = get_metric('Average profit trade:')
    metrics['average_loss_trade'] = get_metric('Average loss trade:')

    # --- Extract deals ---
    deals = []
    in_deals = False
    deals_header_found = False

    for row in t2_rows:
        row_text = ' '.join(row).strip()

        # Find "Deals" section header
        if 'Deals' in row_text and not deals_header_found:
            in_deals = True
            continue

        # Skip column header row (contains "Time", "Deal", etc.)
        if in_deals and not deals_header_found:
            if any('Deal' in cell for cell in row):
                deals_header_found = True
                continue

        # Parse deal data rows
        if deals_header_found:
            # Summary row has 13 cells but first is wide colspan
            # Stop if we hit a spacer or section end
            if len(row) < 10:
                break

            # Skip the summary totals row (identifiable: first cells are empty)
            if row[0].strip() == '' and len(row) >= 12:
                # Check if this looks like the summary row
                has_values = sum(1 for c in row[8:12] if c.strip()) >= 2
                if has_values:
                    continue

            # Regular deal row should have a timestamp in first cell
            if not re.match(r'\d{4}\.\d{2}\.\d{2}', row[0].strip()):
                continue

            deal = {
                'time': row[0].strip(),
                'deal': row[1].strip(),
                'symbol': row[2].strip(),
                'type': row[3].strip(),
                'direction': row[4].strip() if len(row) > 4 else '',
                'volume': row[5].strip() if len(row) > 5 else '',
                'price': row[6].strip() if len(row) > 6 else '',
                'order': row[7].strip() if len(row) > 7 else '',
                'commission': clean_number(row[8]) if len(row) > 8 else 0.0,
                'swap': clean_number(row[9]) if len(row) > 9 else 0.0,
                'profit': clean_number(row[10]) if len(row) > 10 else 0.0,
                'balance': clean_number(row[11]) if len(row) > 11 else 0.0,
                'comment': row[12].strip() if len(row) > 12 else '',
            }
            deals.append(deal)

    return {
        'settings': settings,
        'metrics': metrics,
        'deals': deals,
    }


def output_text(data):
    """Print formatted text summary to stdout."""
    settings = data['settings']
    metrics = data['metrics']
    deals = data['deals']

    print("=" * 70)
    print("  MT5 BACKTEST REPORT")
    print("=" * 70)

    if settings:
        print(f"\n  EA:       {settings.get('expert', 'N/A')}")
        print(f"  Symbol:   {settings.get('symbol', 'N/A')}")
        print(f"  Period:   {settings.get('period', 'N/A')}")
        print(f"  Deposit:  {settings.get('initial_deposit', 'N/A')}")
        print(f"  Leverage: {settings.get('leverage', 'N/A')}")

    print(f"\n{'─' * 70}")
    print("  PERFORMANCE SUMMARY")
    print(f"{'─' * 70}")

    def fmt(val, prefix='', suffix=''):
        if val is None:
            return 'N/A'
        if isinstance(val, float):
            return f"{prefix}{val:,.2f}{suffix}"
        return f"{prefix}{val}{suffix}"

    rows = [
        ('Net Profit', fmt(metrics.get('total_net_profit'), '$')),
        ('Gross Profit', fmt(metrics.get('gross_profit'), '$')),
        ('Gross Loss', fmt(metrics.get('gross_loss'), '$')),
        ('Profit Factor', fmt(metrics.get('profit_factor'))),
        ('Recovery Factor', fmt(metrics.get('recovery_factor'))),
        ('Sharpe Ratio', fmt(metrics.get('sharpe_ratio'))),
        ('Expected Payoff', fmt(metrics.get('expected_payoff'), '$')),
        ('', ''),
        ('Total Trades', str(metrics.get('total_trades', 0))),
        ('Profit Trades', f"{metrics.get('profit_trades', 0)} ({fmt(metrics.get('profit_trades_pct'), suffix='%')})"),
        ('Loss Trades', f"{metrics.get('loss_trades', 0)} ({fmt(metrics.get('loss_trades_pct'), suffix='%')})"),
        ('Short Trades (won)', f"{metrics.get('short_trades', 0)} ({fmt(metrics.get('short_win_pct'), suffix='%')})"),
        ('Long Trades (won)', f"{metrics.get('long_trades', 0)} ({fmt(metrics.get('long_win_pct'), suffix='%')})"),
        ('', ''),
        ('Largest Profit Trade', fmt(metrics.get('largest_profit_trade'), '$')),
        ('Largest Loss Trade', fmt(metrics.get('largest_loss_trade'), '$')),
        ('Average Profit Trade', fmt(metrics.get('average_profit_trade'), '$')),
        ('Average Loss Trade', fmt(metrics.get('average_loss_trade'), '$')),
        ('', ''),
        ('Balance DD Max', f"{fmt(metrics.get('balance_dd_maximal'), '$')} ({fmt(metrics.get('balance_dd_maximal_pct'), suffix='%')})"),
        ('Equity DD Max', f"{fmt(metrics.get('equity_dd_maximal'), '$')} ({fmt(metrics.get('equity_dd_maximal_pct'), suffix='%')})"),
    ]

    for label, value in rows:
        if not label:
            print()
            continue
        print(f"  {label:<25} {value}")

    # Trade summary
    if deals:
        closing_deals = [d for d in deals if d['direction'] == 'out']
        print(f"\n{'─' * 70}")
        print(f"  DEALS ({len(closing_deals)} closing trades)")
        print(f"{'─' * 70}")
        print(f"  {'Time':<22} {'Type':<6} {'Vol':>6} {'Price':>12} {'Profit':>10} {'Balance':>12}")
        print(f"  {'─'*22} {'─'*6} {'─'*6} {'─'*12} {'─'*10} {'─'*12}")
        for d in closing_deals[:50]:  # limit display
            print(f"  {d['time']:<22} {d['type']:<6} {d['volume']:>6} {d['price']:>12} {d['profit']:>10.2f} {d['balance']:>12.2f}")
        if len(closing_deals) > 50:
            print(f"  ... and {len(closing_deals) - 50} more trades")

    print(f"\n{'=' * 70}")


def output_json(data):
    """Print JSON to stdout."""
    print(json.dumps(data, indent=2, default=str))


def output_csv(data):
    """Print CSV to stdout (deals table with metrics header)."""
    out = io.StringIO()
    writer = csv.writer(out)

    # Metrics as header rows
    writer.writerow(['# MT5 Backtest Report'])
    for key, val in data['metrics'].items():
        writer.writerow([f'# {key}', val])
    writer.writerow([])

    # Deals table
    if data['deals']:
        headers = ['time', 'deal', 'symbol', 'type', 'direction', 'volume',
                    'price', 'order', 'commission', 'swap', 'profit', 'balance', 'comment']
        writer.writerow(headers)
        for d in data['deals']:
            writer.writerow([d.get(h, '') for h in headers])

    print(out.getvalue(), end='')


def main():
    if len(sys.argv) < 2:
        print("Usage: parse_report.py <report.html> [text|json|csv]", file=sys.stderr)
        sys.exit(1)

    filepath = sys.argv[1]
    fmt = sys.argv[2] if len(sys.argv) > 2 else 'text'

    data = parse_report(filepath)

    if fmt == 'json':
        output_json(data)
    elif fmt == 'csv':
        output_csv(data)
    else:
        output_text(data)


if __name__ == '__main__':
    main()
