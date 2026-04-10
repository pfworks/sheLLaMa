#!/export/ollama/bin/python3
from flask import Flask, request, jsonify, send_from_directory
import requests
import json
from queue import Queue, PriorityQueue
from threading import Thread, Lock
import time
import uuid
import os

app = Flask(__name__)

# Per-IP token tracking
ip_token_history = {}  # {ip: [{timestamp, tokens}]}
ip_token_lock = Lock()
IP_HISTORY_MAX = 8640  # ~1 day at 10s intervals

# Per-backend token tracking (snapshots of cumulative totals)
backend_token_history = {}  # {url: [{timestamp, tokens}]}
last_backend_tokens = {}    # {url: last_known_total} for computing deltas

def record_ip_tokens(ip, tokens):
    """Record token usage for a client IP"""
    if tokens <= 0:
        return
    with ip_token_lock:
        if ip not in ip_token_history:
            ip_token_history[ip] = []
        ip_token_history[ip].append({'timestamp': time.time(), 'tokens': tokens})
        # Trim old entries
        if len(ip_token_history[ip]) > IP_HISTORY_MAX:
            ip_token_history[ip] = ip_token_history[ip][-IP_HISTORY_MAX:]

# Load backends from config file
def load_backends():
    config_file = os.path.join(os.path.dirname(__file__), 'backends.json')
    try:
        with open(config_file, 'r') as f:
            backends = json.load(f)['backends']
            # Support both old format (list of strings) and new format (list of dicts)
            if backends and isinstance(backends[0], str):
                return [{'url': url, 'weight': 1, 'max_model': 'codellama:70b'} for url in backends]
            # Ensure max_model exists
            for b in backends:
                if 'max_model' not in b:
                    b['max_model'] = 'codellama:70b'
            return backends
    except:
        return [{'url': 'http://localhost:5001', 'weight': 1, 'max_model': 'codellama:70b'}]

BACKENDS = load_backends()

# Model size ordering for comparison
MODEL_SIZES = {
    'codellama:7b': 2,
    'codellama:13b': 3,
    'codellama:34b': 4,
    'codellama:70b': 5,
    'deepseek-coder:1.3b': 1,
    'deepseek-coder:6.7b': 2,
    'deepseek-coder:33b': 4,
    'qwen2.5-coder:0.5b': 1,
    'qwen2.5-coder:1.5b': 1,
    'qwen2.5-coder:3b': 1,
    'qwen2.5-coder:7b': 2,
    'qwen2.5-coder:14b': 3,
    'qwen2.5-coder:32b': 4
}

# Track backend availability and queue size
backend_status = {b['url']: {'available': True, 'queue_size': 0, 'weight': b['weight'], 'max_model': b['max_model']} for b in BACKENDS}
backend_lock = Lock()

def get_backend_queue_size(url):
    """Check backend queue size and capacity stats"""
    try:
        resp = requests.get(
            f"{url}/queue-status", 
            timeout=2
        )
        data = resp.json()
        return data
    except:
        return None

def get_available_backend(requested_model='codellama:13b', wait=True, timeout=300):
    """Get backend with lowest weighted queue score that supports the requested model.
    Among same-weight backends, prefer those with more free RAM and lower CPU usage."""
    import time
    start_time = time.time()
    
    while True:
        with backend_lock:
            # Update queue sizes and capacity
            for backend in BACKENDS:
                url = backend['url']
                if backend_status[url]['available']:
                    data = get_backend_queue_size(url)
                    if data:
                        backend_status[url]['queue_size'] = data.get('queue_size', 999)
                        backend_status[url]['cpu_percent'] = data.get('cpu_percent', 50)
                        backend_status[url]['ram_available_gb'] = data.get('ram_available_gb', 0)
                        backend_status[url]['ram_total_gb'] = data.get('ram_total_gb', 16)
                        backend_status[url]['cpu_arch'] = data.get('cpu_arch', 'x86_64')
                        backend_status[url]['cpu_count'] = data.get('cpu_count', 4)
                        backend_status[url]['cpu_freq_mhz'] = data.get('cpu_freq_mhz', 2000)
                    else:
                        backend_status[url]['queue_size'] = 999
            
            # Filter backends that support the requested model
            requested_size = MODEL_SIZES.get(requested_model, 2)
            available = []
            for url in backend_status.keys():
                if backend_status[url]['available']:
                    max_model = backend_status[url]['max_model']
                    max_size = MODEL_SIZES.get(max_model, 4)
                    if requested_size <= max_size:
                        qs = backend_status[url]['queue_size']
                        w = backend_status[url]['weight']
                        cpu = backend_status[url].get('cpu_percent', 50)
                        ram = backend_status[url].get('ram_available_gb', 0)
                        # Score: lower is better
                        # queue_size is primary, weight reduces score
                        # cpu adds 0-1 penalty, total ram gives capacity bonus
                        # Apple Silicon (arm64) gets major bonus for unified memory / neural engine
                        # CPU frequency normalized to 5GHz scale
                        ram_total = backend_status[url].get('ram_total_gb', 16)
                        arch = backend_status[url].get('cpu_arch', 'x86_64')
                        freq = backend_status[url].get('cpu_freq_mhz', 2000)
                        arch_multiplier = 3.0 if arch == 'arm64' else 1.0
                        score = qs - (w * 0.1) + (cpu / 100.0) - (ram_total / 128.0) * arch_multiplier - (freq / 5000.0)
                        available.append((url, score))
            
            if available:
                best_backend = min(available, key=lambda x: x[1])[0]
                backend_status[best_backend]['available'] = False
                return best_backend
        
        # If no backend available and not waiting, return None
        if not wait:
            return None
        
        # Check timeout
        if time.time() - start_time > timeout:
            return None
        
        # Wait a bit before retrying
        time.sleep(0.5)

def release_backend(url):
    """Mark backend as available"""
    with backend_lock:
        backend_status[url]['available'] = True

def proxy_request(endpoint, data, client_ip=None):
    """Send request to available backend with keepalive"""
    model = data.get('model', 'codellama:13b')
    backend = get_available_backend(model)
    if not backend:
        return {'error': f'No backends available that support model {model}. Check backends.json configuration.'}, 200
    
    try:
        session = requests.Session()
        session.headers.update({'Connection': 'keep-alive'})
        
        response = session.post(
            f"{backend}{endpoint}", 
            json=data, 
            timeout=3600,
            stream=False
        )
        result = response.json()
        
        # Check if result was lost
        if result.get('error') and 'result was lost' in result.get('error', ''):
            return {'error': f"Backend {backend} lost task result. Task may have completed but response was not stored."}, 500
        
        # Record tokens for this client IP
        if client_ip:
            record_ip_tokens(client_ip, result.get('total_tokens', 0))
        
        return result, 200
    except requests.exceptions.Timeout:
        return {'error': f'Backend {backend} request timed out after 3600 seconds'}, 500
    except Exception as e:
        return {'error': f'Backend error: {str(e)}'}, 500
    finally:
        release_backend(backend)

def split_and_process(commands, model, chunk_size=10):
    """Split commands into chunks and process in parallel"""
    lines = commands.strip().split('\n')
    if len(lines) <= chunk_size:
        return proxy_request('/generate', {'commands': commands, 'model': model})
    
    # Split into chunks
    chunks = ['\n'.join(lines[i:i+chunk_size]) for i in range(0, len(lines), chunk_size)]
    results = []
    threads = []
    
    def process_chunk(chunk, idx):
        result, _ = proxy_request('/generate', {'commands': chunk, 'model': model})
        results.append((idx, result))
    
    for idx, chunk in enumerate(chunks):
        t = Thread(target=process_chunk, args=(chunk, idx))
        t.start()
        threads.append(t)
    
    for t in threads:
        t.join()
    
    # Combine results
    results.sort(key=lambda x: x[0])
    combined = '\n---\n'.join([r[1].get('playbook', '') for r in results])
    total_time = sum([r[1].get('elapsed', 0) for r in results])
    
    return {
        'playbook': combined,
        'elapsed': round(max([r[1].get('elapsed', 0) for r in results]), 2),
        'total_tokens': sum([r[1].get('total_tokens', 0) for r in results]),
        'chunks_processed': len(chunks)
    }, 200

@app.route('/')
def index():
    return send_from_directory('/export/html', 'index.html')

@app.route('/status')
def status_page():
    return send_from_directory('/export/html', 'status.html')

@app.route('/queue-status')
def queue_status():
    """Aggregate queue status from all backends"""
    backends_info = []
    total_queue = 0
    active_count = 0
    total_requests = 0
    total_tokens = 0
    
    for backend in BACKENDS:
        url = backend['url']
        weight = backend['weight']
        max_model = backend.get('max_model', 'codellama:70b')
        try:
            resp = requests.get(
                f"{url}/queue-status", 
                timeout=2
            )
            data = resp.json()
            queue_size = data.get('queue_size', 0)
            total_queue += queue_size
            is_active = data.get('active', False)
            if is_active:
                active_count += 1
            
            # Aggregate stats
            total_requests += data.get('total_requests', 0)
            total_tokens += data.get('total_tokens', 0)
            
            cpu_pct = data.get('cpu_percent', 0)
            ram_avail = data.get('ram_available_gb', 0)
            ram_total = data.get('ram_total_gb', 0)
            backends_info.append({
                'url': url,
                'weight': weight,
                'max_model': max_model,
                'queue_size': queue_size,
                'active': is_active,
                'status': 'online',
                'active_model': data.get('active_model', 'none'),
                'tokens': data.get('total_tokens', 0),
                'cpu_percent': cpu_pct,
                'ram_available_gb': ram_avail,
                'ram_total_gb': ram_total,
                'cpu_arch': data.get('cpu_arch', 'x86_64'),
                'cpu_count': data.get('cpu_count', 0),
                'cpu_freq_mhz': data.get('cpu_freq_mhz', 0)
            })
        except:
            backends_info.append({
                'url': url,
                'weight': weight,
                'max_model': max_model,
                'queue_size': 0,
                'active': False,
                'status': 'offline',
                'active_model': 'none',
                'tokens': 0,
                'cpu_percent': 0,
                'ram_available_gb': 0,
                'ram_total_gb': 0,
                'cpu_arch': 'unknown',
                'cpu_count': 0,
                'cpu_freq_mhz': 0
            })
    
    # Record per-backend token deltas
    now = time.time()
    with ip_token_lock:
        for b in backends_info:
            url = b['url']
            cur = b.get('tokens', 0)
            prev = last_backend_tokens.get(url, cur)
            delta = cur - prev
            last_backend_tokens[url] = cur
            if delta > 0:
                if url not in backend_token_history:
                    backend_token_history[url] = []
                backend_token_history[url].append({'timestamp': now, 'tokens': delta})
                if len(backend_token_history[url]) > IP_HISTORY_MAX:
                    backend_token_history[url] = backend_token_history[url][-IP_HISTORY_MAX:]

    return jsonify({
        'queue_size': total_queue,
        'active': active_count > 0,
        'active_backends': active_count,
        'total_backends': len(BACKENDS),
        'total_requests': total_requests,
        'total_tokens': total_tokens,
        'backends': backends_info,
        'timestamp': time.time()
    })

@app.route('/generate', methods=['POST'])
def generate():
    commands = request.json.get('commands', '')
    model = request.json.get('model', 'codellama:13b')
    split = request.json.get('split', False)
    client_ip = request.remote_addr
    
    if split:
        result, status = split_and_process(commands, model)
    else:
        result, status = proxy_request('/generate', {'commands': commands, 'model': model}, client_ip)
    
    return jsonify(result), status

@app.route('/explain', methods=['POST'])
def explain():
    playbook = request.json.get('playbook', '')
    model = request.json.get('model', 'codellama:13b')
    result, status = proxy_request('/explain', {'playbook': playbook, 'model': model}, request.remote_addr)
    return jsonify(result), status

@app.route('/generate-code', methods=['POST'])
def generate_code_endpoint():
    description = request.json.get('description', '')
    model = request.json.get('model', 'codellama:13b')
    result, status = proxy_request('/generate-code', {'description': description, 'model': model}, request.remote_addr)
    return jsonify(result), status

@app.route('/explain-code', methods=['POST'])
def explain_code_endpoint():
    code = request.json.get('code', '')
    model = request.json.get('model', 'codellama:13b')
    result, status = proxy_request('/explain-code', {'code': code, 'model': model}, request.remote_addr)
    return jsonify(result), status

@app.route('/chat', methods=['POST'])
def chat_endpoint():
    message = request.json.get('message', '')
    model = request.json.get('model', 'codellama:13b')
    result, status = proxy_request('/chat', {'message': message, 'model': model}, request.remote_addr)
    return jsonify(result), status

@app.route('/analyze', methods=['POST'])
def analyze_endpoint():
    files = request.json.get('files', [])
    model = request.json.get('model', 'codellama:13b')
    client_ip = request.remote_addr
    
    # If we have multiple files, check if we should process in parallel or sequential
    if len(files) > 1:
        # Count available backends that support this model
        requested_size = MODEL_SIZES.get(model, 2)
        available_backends = 0
        for backend in BACKENDS:
            max_size = MODEL_SIZES.get(backend.get('max_model', 'codellama:70b'), 4)
            if requested_size <= max_size:
                available_backends += 1
        
        # If only 1 backend, process sequentially to avoid timeout
        if available_backends <= 1:
            combined_parts = []
            total_elapsed = 0
            total_tokens = 0
            
            for idx, file_data in enumerate(files):
                result, status = proxy_request('/analyze', {'files': [file_data], 'model': model}, client_ip)
                if result.get('error'):
                    return jsonify({'error': f"Error processing {file_data.get('path', f'file {idx}')}: {result['error']}"}), 200
                
                analysis = result.get('analysis', '')
                file_path = file_data.get('path', f'File {idx+1}')
                combined_parts.append(f"--- {file_path} ---\n{analysis}")
                total_elapsed = max(total_elapsed, result.get('elapsed', 0))
                total_tokens += result.get('total_tokens', 0)
            
            return jsonify({
                'analysis': "\n\n".join(combined_parts),
                'elapsed': round(total_elapsed, 2),
                'total_tokens': total_tokens,
                'files_processed': len(files),
                'parallel': False
            }), 200
        
        # Multiple backends available, process in parallel
        results = []
        threads = []
        
        def process_file(file_data, idx):
            result, status = proxy_request('/analyze', {'files': [file_data], 'model': model}, client_ip)
            results.append((idx, result, status))
        
        for idx, file_data in enumerate(files):
            t = Thread(target=process_file, args=(file_data, idx))
            t.start()
            threads.append(t)
        
        for t in threads:
            t.join()
        
        # Check for errors
        errors = [r[1].get('error') for r in results if r[1].get('error')]
        if errors:
            return jsonify({'error': f"Errors from backends: {'; '.join(errors)}"}), 200
        
        # Combine analyses
        results.sort(key=lambda x: x[0])
        combined_parts = []
        for idx, (_, result, _) in enumerate(results, 1):
            analysis = result.get('analysis', '')
            file_path = files[idx-1].get('path', f'File {idx}')
            combined_parts.append(f"--- {file_path} ---\n{analysis}")
        
        combined_analysis = "\n\n".join(combined_parts)
        
        total_elapsed = max([r[1].get('elapsed', 0) for r in results])
        total_tokens = sum([r[1].get('total_tokens', 0) for r in results])
        
        return jsonify({
            'analysis': combined_analysis,
            'elapsed': round(total_elapsed, 2),
            'total_tokens': total_tokens,
            'files_processed': len(files),
            'parallel': True
        }), 200
    else:
        # Single file processing
        result, status = proxy_request('/analyze', {'files': files, 'model': model}, client_ip)
        return jsonify(result), status

@app.route('/ip-tokens')
def ip_tokens():
    """Return token usage history per client IP and per backend"""
    with ip_token_lock:
        result = {ip: entries for ip, entries in ip_token_history.items()}
        for url, entries in backend_token_history.items():
            result[f"backend:{url}"] = entries
        return jsonify(result)

@app.route('/generate-image', methods=['POST'])
def generate_image_endpoint():
    data = request.json
    # Image generation doesn't use an LLM model, pick any available backend
    result, status = proxy_request('/generate-image', data, request.remote_addr)
    return jsonify(result), status

@app.route('/image-models')
def image_models():
    """Proxy to any online backend"""
    for backend in BACKENDS:
        try:
            resp = requests.get(f"{backend['url']}/image-models", timeout=5)
            return jsonify(resp.json())
        except:
            continue
    return jsonify({'models': []})

@app.route('/upload', methods=['POST'])
def upload():
    if 'file' not in request.files:
        return jsonify({'error': 'No file provided'}), 400
    
    file = request.files['file']
    commands = file.read().decode('utf-8')
    model = request.form.get('model', 'codellama:13b')
    
    result, status = proxy_request('/generate', {'commands': commands, 'model': model}, request.remote_addr)
    return jsonify(result), status

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
