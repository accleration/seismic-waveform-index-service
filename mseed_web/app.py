from flask import Flask, render_template, request, send_file, flash, redirect, url_for, session
import requests
from io import BytesIO
import os
from functools import wraps
from database import init_db, save_record, get_all_records, get_records_count

app = Flask(__name__)
# 会话密钥：优先从环境变量 SECRET_KEY 读取，未设置时每次启动随机生成（重启后旧会话失效）
app.secret_key = os.environ.get('SECRET_KEY') or os.urandom(24)

BASE_URL = os.environ.get("FDSNWS_BASE_URL", "http://127.0.0.1:8082/fdsnws/dataselect/1/query")  # 指向 portable-fdsnws-dataselect 服务

# 管理员密码（必须通过环境变量 ADMIN_PASSWORD 设置，禁止硬编码默认口令）
ADMIN_PASSWORD = os.environ.get('ADMIN_PASSWORD')
if not ADMIN_PASSWORD:
    raise RuntimeError("环境变量 ADMIN_PASSWORD 未设置，请通过环境变量配置管理员密码后再启动")

# 初始化数据库
init_db()


def admin_required(f):
    """管理员权限装饰器"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not session.get('admin_logged_in'):
            flash('请先登录管理员账户', 'error')
            return redirect(url_for('admin_login'))
        return f(*args, **kwargs)
    return decorated_function


def get_client_ip():
    """获取客户端真实IP地址"""
    if request.headers.get('X-Forwarded-For'):
        ip = request.headers.get('X-Forwarded-For').split(',')[0].strip()
    elif request.headers.get('X-Real-IP'):
        ip = request.headers.get('X-Real-IP')
    else:
        ip = request.remote_addr
    return ip


@app.route('/', methods=['GET', 'POST'])
def index():
    if request.method == 'POST':
        # 获取表单参数
        net = request.form.get('net', '').strip()
        sta = request.form.get('sta', '').strip()
        loc = request.form.get('loc', '').strip()
        cha = request.form.get('cha', '').strip()
        start = request.form.get('start', '').strip()
        end = request.form.get('end', '').strip()
        
        # 获取客户端IP
        client_ip = get_client_ip()
        
        # 验证必填字段
        if not all([net, sta, loc, cha, start, end]):
            flash('请填写所有必填字段', 'error')
            # 记录失败的请求
            save_record(client_ip, net, sta, loc, cha, start, end, 
                       status_code=None, status_message='缺少必填字段', success=False)
            return redirect(url_for('index'))
        
        # 构建URL
        params = {
            'net': net,
            'sta': sta,
            'loc': loc,
            'cha': cha,
            'start': start,
            'end': end,
            'nodata': '404'
        }
        
        try:
            # 访问目标网站并下载数据
            response = requests.get(BASE_URL, params=params, timeout=60)
            
            if response.status_code == 200:
                # 记录成功的请求
                save_record(client_ip, net, sta, loc, cha, start, end,
                           status_code=200, status_message='成功', success=True)
                
                # 创建文件名（将冒号和点替换为连字符，保留T作为时间分隔符）
                start_safe = start.replace(':', '-').replace('.', '-')
                filename = f"data_{net}_{sta}_{loc}_{cha}_{start_safe}.mseed"
                # 清理文件名中的特殊字符
                filename = filename.replace('/', '-')[:150]
                
                # 将数据保存到内存中的BytesIO对象
                data = BytesIO(response.content)
                data.seek(0)
                
                # 返回文件下载
                return send_file(
                    data,
                    mimetype='application/octet-stream',
                    as_attachment=True,
                    download_name=filename
                )
            elif response.status_code == 404:
                flash('未找到数据，请检查参数是否正确', 'error')
                save_record(client_ip, net, sta, loc, cha, start, end,
                           status_code=404, status_message='未找到数据', success=False)
            else:
                flash(f'服务器返回错误: {response.status_code}', 'error')
                save_record(client_ip, net, sta, loc, cha, start, end,
                           status_code=response.status_code, 
                           status_message=f'服务器错误: {response.status_code}', success=False)
                
        except requests.exceptions.RequestException as e:
            flash(f'请求失败: {str(e)}', 'error')
            save_record(client_ip, net, sta, loc, cha, start, end,
                       status_code=None, status_message=f'请求异常: {str(e)}', success=False)
        
        return redirect(url_for('index'))
    
    # GET请求，显示表单
    return render_template('index.html')


@app.route('/admin/login', methods=['GET', 'POST'])
def admin_login():
    """管理员登录页面"""
    if request.method == 'POST':
        password = request.form.get('password', '').strip()
        if password == ADMIN_PASSWORD:
            session['admin_logged_in'] = True
            flash('登录成功', 'success')
            return redirect(url_for('records'))
        else:
            flash('密码错误', 'error')
    
    return render_template('admin_login.html')


@app.route('/admin/logout')
def admin_logout():
    """管理员登出"""
    session.pop('admin_logged_in', None)
    # 不显示消息，直接重定向到首页，避免在数据截取工具界面显示不相关的消息
    return redirect(url_for('index'))


@app.route('/records')
@admin_required
def records():
    """查看访问记录页面（需要管理员权限）"""
    page = request.args.get('page', 1, type=int)
    per_page = 50
    offset = (page - 1) * per_page
    
    records_list = get_all_records(limit=per_page, offset=offset)
    total_count = get_records_count()
    total_pages = (total_count + per_page - 1) // per_page
    
    return render_template('records.html', 
                         records=records_list,
                         current_page=page,
                         total_pages=total_pages,
                         total_count=total_count)


if __name__ == '__main__':
    app.run(debug=os.environ.get('FLASK_DEBUG', '0') == '1',
        host=os.environ.get('HOST', '0.0.0.0'),
        port=int(os.environ.get('PORT', '5000')))

