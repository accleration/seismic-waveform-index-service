import sqlite3
import os
from datetime import datetime
from contextlib import contextmanager

DB_NAME = 'access_records.db'


def init_db():
    """初始化数据库，创建表结构"""
    conn = sqlite3.connect(DB_NAME)
    cursor = conn.cursor()
    
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS access_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ip_address TEXT NOT NULL,
            net TEXT NOT NULL,
            sta TEXT NOT NULL,
            loc TEXT NOT NULL,
            cha TEXT NOT NULL,
            start_time TEXT NOT NULL,
            end_time TEXT NOT NULL,
            request_time TEXT NOT NULL,
            status_code INTEGER,
            status_message TEXT,
            success INTEGER DEFAULT 0
        )
    ''')
    
    conn.commit()
    conn.close()


@contextmanager
def get_db():
    """获取数据库连接的上下文管理器"""
    conn = sqlite3.connect(DB_NAME)
    conn.row_factory = sqlite3.Row  # 使返回结果为字典形式
    try:
        yield conn
    finally:
        conn.close()


def save_record(ip_address, net, sta, loc, cha, start_time, end_time, 
                status_code=None, status_message=None, success=False):
    """保存访问记录"""
    request_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute('''
            INSERT INTO access_records 
            (ip_address, net, sta, loc, cha, start_time, end_time, 
             request_time, status_code, status_message, success)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''', (ip_address, net, sta, loc, cha, start_time, end_time,
              request_time, status_code, status_message, 1 if success else 0))
        conn.commit()


def get_all_records(limit=100, offset=0):
    """获取所有访问记录"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute('''
            SELECT * FROM access_records 
            ORDER BY request_time DESC 
            LIMIT ? OFFSET ?
        ''', (limit, offset))
        return [dict(row) for row in cursor.fetchall()]


def get_records_count():
    """获取记录总数"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute('SELECT COUNT(*) as count FROM access_records')
        return cursor.fetchone()['count']


def get_records_by_ip(ip_address, limit=100):
    """根据IP地址获取记录"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute('''
            SELECT * FROM access_records 
            WHERE ip_address = ?
            ORDER BY request_time DESC 
            LIMIT ?
        ''', (ip_address, limit))
        return [dict(row) for row in cursor.fetchall()]

