#!/usr/bin/env python3
"""Incremental JD Union order statistics collector and read-only HTTP API."""

import argparse
import json
import os
import sqlite3
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

from jd_order import TIME_FORMAT, make_client


SHANGHAI = timezone(timedelta(hours=8))
INVALID_CODES = {3, 13, 14}


def now_shanghai():
    return datetime.now(SHANGHAI)


def parse_jd_time(value):
    if not value:
        return None
    try:
        return datetime.strptime(value, TIME_FORMAT).replace(tzinfo=SHANGHAI)
    except (TypeError, ValueError):
        return None


class OrderStore:
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.initialize()

    def connect(self):
        connection = sqlite3.connect(self.path, timeout=30)
        connection.row_factory = sqlite3.Row
        return connection

    def initialize(self):
        with self.connect() as db:
            db.executescript(
                """
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS order_rows (
                    row_id TEXT PRIMARY KEY,
                    order_id TEXT NOT NULL,
                    sku_id TEXT NOT NULL,
                    order_time TEXT NOT NULL,
                    modify_time TEXT,
                    finish_time TEXT,
                    valid_code INTEGER NOT NULL,
                    sku_num INTEGER NOT NULL,
                    sku_return_num INTEGER NOT NULL,
                    estimate_cos_price REAL NOT NULL,
                    estimate_fee REAL NOT NULL,
                    actual_cos_price REAL NOT NULL,
                    actual_fee REAL NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_order_rows_order_time
                    ON order_rows(order_time);
                CREATE INDEX IF NOT EXISTS idx_order_rows_order_id
                    ON order_rows(order_id);
                CREATE TABLE IF NOT EXISTS metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """
            )

    def metadata(self, key):
        with self.connect() as db:
            row = db.execute(
                "SELECT value FROM metadata WHERE key = ?", (key,)
            ).fetchone()
            return row["value"] if row else None

    def set_metadata(self, key, value):
        with self.connect() as db:
            db.execute(
                """
                INSERT INTO metadata(key, value) VALUES(?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                (key, value),
            )

    def upsert_rows(self, rows):
        stamp = now_shanghai().isoformat()
        values = []
        for row in rows:
            order_id = str(row.get("orderId") or "")
            sku_id = str(row.get("skuId") or "")
            row_id = str(row.get("id") or "{}:{}".format(order_id, sku_id))
            if not row_id or not order_id or not row.get("orderTime"):
                continue
            values.append(
                (
                    row_id,
                    order_id,
                    sku_id,
                    str(row.get("orderTime") or ""),
                    str(row.get("modifyTime") or ""),
                    str(row.get("finishTime") or ""),
                    int(row.get("validCode") or 0),
                    int(row.get("skuNum") or 0),
                    int(row.get("skuReturnNum") or 0),
                    float(row.get("estimateCosPrice") or 0),
                    float(row.get("estimateFee") or 0),
                    float(row.get("actualCosPrice") or 0),
                    float(row.get("actualFee") or 0),
                    stamp,
                )
            )
        if not values:
            return 0
        with self.lock, self.connect() as db:
            db.executemany(
                """
                INSERT INTO order_rows(
                    row_id, order_id, sku_id, order_time, modify_time,
                    finish_time, valid_code, sku_num, sku_return_num,
                    estimate_cos_price, estimate_fee, actual_cos_price,
                    actual_fee, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(row_id) DO UPDATE SET
                    order_id = excluded.order_id,
                    sku_id = excluded.sku_id,
                    order_time = excluded.order_time,
                    modify_time = excluded.modify_time,
                    finish_time = excluded.finish_time,
                    valid_code = excluded.valid_code,
                    sku_num = excluded.sku_num,
                    sku_return_num = excluded.sku_return_num,
                    estimate_cos_price = excluded.estimate_cos_price,
                    estimate_fee = excluded.estimate_fee,
                    actual_cos_price = excluded.actual_cos_price,
                    actual_fee = excluded.actual_fee,
                    updated_at = excluded.updated_at
                """,
                values,
            )
        return len(values)

    def summary(self, start, end):
        placeholders = ",".join("?" for _ in INVALID_CODES)
        params = [
            start.strftime(TIME_FORMAT),
            end.strftime(TIME_FORMAT),
        ] + sorted(INVALID_CODES)
        query = """
            SELECT
                COUNT(DISTINCT order_id) AS order_count,
                COALESCE(SUM(sku_num), 0) AS item_count,
                COALESCE(SUM(sku_return_num), 0) AS returned_items,
                COALESCE(SUM(estimate_cos_price), 0) AS estimated_sales,
                COALESCE(SUM(estimate_fee), 0) AS estimated_commission,
                COALESCE(SUM(actual_cos_price), 0) AS actual_sales,
                COALESCE(SUM(actual_fee), 0) AS actual_commission
            FROM order_rows
            WHERE order_time >= ? AND order_time < ?
              AND valid_code NOT IN ({})
        """.format(placeholders)
        with self.connect() as db:
            row = db.execute(query, params).fetchone()
        return {
            "orders": int(row["order_count"]),
            "items": int(row["item_count"]),
            "returnedItems": int(row["returned_items"]),
            "estimatedSales": round(float(row["estimated_sales"]), 2),
            "estimatedCommission": round(
                float(row["estimated_commission"]), 2
            ),
            "actualSales": round(float(row["actual_sales"]), 2),
            "actualCommission": round(float(row["actual_commission"]), 2),
        }

    def status(self):
        with self.connect() as db:
            row = db.execute(
                "SELECT COUNT(*) AS rows, MAX(updated_at) AS updated FROM order_rows"
            ).fetchone()
        return {
            "storedRows": int(row["rows"]),
            "lastUpdated": row["updated"],
            "syncCursor": self.metadata("sync_cursor"),
            "lastError": self.metadata("last_error"),
        }


class Collector(threading.Thread):
    def __init__(self, store):
        super().__init__(name="jd-order-collector", daemon=True)
        self.store = store
        self.client = make_client()
        self.stop_event = threading.Event()

    def initial_cursor(self):
        saved = parse_jd_time(self.store.metadata("sync_cursor"))
        if saved:
            return saved
        return now_shanghai() - timedelta(days=90)

    def fetch_window(self, start, end, query_type=3):
        page = 1
        collected = 0
        while not self.stop_event.is_set():
            result = self.client.query_order_rows(
                start.strftime(TIME_FORMAT),
                end.strftime(TIME_FORMAT),
                query_type=query_type,
                page_index=page,
                page_size=500,
            )
            if str(result.get("code", "200")) not in ("0", "200"):
                raise RuntimeError(result.get("message") or str(result))
            rows = result.get("data") or []
            collected += self.store.upsert_rows(rows)
            if not result.get("hasMore"):
                break
            page += 1
            time.sleep(0.2)
        return collected

    def seed_recent_orders(self):
        """Populate current day/week/month first so live dashboards are useful."""
        current = now_shanghai()
        month_key = current.strftime("%Y-%m")
        if self.store.metadata("recent_seed_month") == month_key:
            return
        day_start = current.replace(hour=0, minute=0, second=0, microsecond=0)
        week_start = day_start - timedelta(days=day_start.weekday())
        month_start = day_start.replace(day=1)
        boundaries = [day_start, week_start, month_start]
        seeded_to = current
        for boundary in boundaries:
            cursor = seeded_to
            while cursor > boundary and not self.stop_event.is_set():
                window_start = max(boundary, cursor - timedelta(hours=1))
                self.fetch_window(window_start, cursor, query_type=1)
                cursor = window_start
                self.stop_event.wait(0.5)
            seeded_to = boundary
        self.store.set_metadata("recent_seed_month", month_key)

    def run(self):
        cursor = self.initial_cursor()
        try:
            self.seed_recent_orders()
            self.store.set_metadata("last_error", "")
        except Exception as exc:
            self.store.set_metadata("last_error", str(exc)[:500])
        while not self.stop_event.is_set():
            current = now_shanghai()
            try:
                if cursor < current - timedelta(minutes=5):
                    window_end = min(cursor + timedelta(hours=1), current)
                    self.fetch_window(cursor, window_end)
                    cursor = window_end
                    self.store.set_metadata(
                        "sync_cursor", cursor.strftime(TIME_FORMAT)
                    )
                    self.store.set_metadata("last_error", "")
                    self.stop_event.wait(0.5)
                else:
                    overlap_start = current - timedelta(minutes=10)
                    self.fetch_window(overlap_start, current)
                    cursor = current
                    self.store.set_metadata(
                        "sync_cursor", cursor.strftime(TIME_FORMAT)
                    )
                    self.store.set_metadata("last_error", "")
                    self.stop_event.wait(60)
            except Exception as exc:
                self.store.set_metadata("last_error", str(exc)[:500])
                self.stop_event.wait(60)


def period_ranges(now):
    day_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    week_start = day_start - timedelta(days=day_start.weekday())
    month_start = day_start.replace(day=1)
    year_start = day_start.replace(month=1, day=1)
    return {
        "day": (day_start, now),
        "week": (week_start, now),
        "month": (month_start, now),
        "year": (year_start, now),
    }


def make_handler(store, api_token):
    class Handler(BaseHTTPRequestHandler):
        server_version = "JDStats/1.0"

        def send_json(self, status, payload):
            body = json.dumps(
                payload, ensure_ascii=False, separators=(",", ":")
            ).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = urlparse(self.path).path.rstrip("/")
            if path == "/health":
                self.send_json(200, {"ok": True})
                return
            if path != "/api/jd/stats":
                self.send_json(404, {"error": "not_found"})
                return
            authorization = self.headers.get("Authorization", "")
            if not api_token or authorization != "Bearer " + api_token:
                self.send_json(401, {"error": "unauthorized"})
                return
            now = now_shanghai()
            summaries = {
                name: store.summary(start, end)
                for name, (start, end) in period_ranges(now).items()
            }
            self.send_json(
                200,
                {
                    "generatedAt": now.isoformat(),
                    "timezone": "Asia/Shanghai",
                    "periods": summaries,
                    "sync": store.status(),
                },
            )

        def log_message(self, format_string, *args):
            return

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18732)
    parser.add_argument(
        "--database",
        default=os.path.join(os.path.dirname(__file__), "jd_stats.sqlite3"),
    )
    parser.add_argument("--no-collector", action="store_true")
    args = parser.parse_args()

    api_token = os.getenv("JD_STATS_API_TOKEN", "")
    if not api_token:
        raise SystemExit("JD_STATS_API_TOKEN is required")

    store = OrderStore(args.database)
    collector = None
    if not args.no_collector:
        collector = Collector(store)
        collector.start()

    server = ThreadingHTTPServer(
        (args.host, args.port), make_handler(store, api_token)
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if collector:
            collector.stop_event.set()
        server.server_close()


if __name__ == "__main__":
    main()
