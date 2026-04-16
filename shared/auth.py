"""sheLLaMa authentication — API keys + SSO (OIDC) with roles and per-key tracking."""
import json
import os
import time
from functools import wraps
from flask import request, jsonify, redirect, session, url_for

AUTH_FILE = os.environ.get('SHELLAMA_AUTH_FILE', '/etc/shellama/auth.json')

# Roles and their permissions
ROLE_PERMISSIONS = {
    'admin': {
        'endpoints': ['all'],
        'web_modify': True,
        'cloud_fallback': True,
    },
    'user': {
        'endpoints': ['chat', 'generate', 'explain', 'generate-code', 'explain-code',
                      'analyze', 'generate-image', 'upload', 'test', 'models',
                      'image-models', 'queue-status', 'cloud-costs', 'cost-history'],
        'web_modify': False,
        'cloud_fallback': True,
    },
    'viewer': {
        'endpoints': ['queue-status', 'models', 'image-models', 'cloud-costs',
                      'cost-history', 'ip-tokens', 'queue-history', 'usage-stats'],
        'web_modify': False,
        'cloud_fallback': False,
    },
}

# Pages that serve HTML — SSO protects these, API keys protect API endpoints
WEB_PAGES = ['/', '/status', '/backends', '/stats', '/costs']

_config = None
_config_mtime = 0
_oauth = None

# Rate limiting: {key: [timestamp, timestamp, ...]}
_rate_requests = {}
_rate_tokens = {}


def _check_rate_limit(key, key_info):
    """Check rate limits and budget. Returns error string or None."""
    limits = key_info.get('rate_limit', {})
    budget = key_info.get('budget', {})
    if not limits and not budget:
        return None

    now = time.time()

    # Requests per minute
    rpm = limits.get('rpm')
    if rpm:
        window = [t for t in _rate_requests.get(key, []) if t > now - 60]
        _rate_requests[key] = window
        if len(window) >= rpm:
            return f'Rate limit exceeded: {rpm} requests/minute'
        window.append(now)

    # Tokens per day
    tpd = limits.get('tpd')
    if tpd:
        day_start = now - 86400
        day_tokens = sum(e[1] for e in _rate_tokens.get(key, []) if e[0] > day_start)
        if day_tokens >= tpd:
            return f'Rate limit exceeded: {tpd} tokens/day'

    # Budget per day (estimated cloud cost)
    max_cost = budget.get('max_daily')
    if max_cost:
        day_start = now - 86400
        entries = [e for e in _rate_tokens.get(key, []) if e[0] > day_start]
        # Actual cloud fallback cost (real spend)
        cloud_prompt = sum(e[2] for e in entries if e[4])
        cloud_resp = sum(e[3] for e in entries if e[4])
        # Hypothetical cost for local usage (what it would cost on cloud)
        local_prompt = sum(e[2] for e in entries if not e[4])
        local_resp = sum(e[3] for e in entries if not e[4])
        # Use GPT-4o rates as reference for local, actual rates for cloud
        actual_cost = (cloud_prompt * 2.50 + cloud_resp * 10.00) / 1_000_000
        hypothetical_cost = (local_prompt * 2.50 + local_resp * 10.00) / 1_000_000
        # Budget enforced on actual cloud spend only
        if actual_cost >= max_cost:
            return f'Budget exceeded: ${actual_cost:.4f} actual cloud spend of ${max_cost:.2f}/day limit'

    return None


def record_rate_tokens(key, tokens, prompt_tokens=0, response_tokens=0, cloud_fallback=False):
    """Record token usage for rate limiting and budget tracking."""
    if key:
        if key not in _rate_tokens:
            _rate_tokens[key] = []
        _rate_tokens[key].append((time.time(), tokens, prompt_tokens, response_tokens, cloud_fallback))
        # Trim old entries (keep 24h)
        cutoff = time.time() - 86400
        _rate_tokens[key] = [e for e in _rate_tokens[key] if e[0] > cutoff]


def _load_config():
    """Load auth config, reload if file changed."""
    global _config, _config_mtime
    try:
        mtime = os.path.getmtime(AUTH_FILE)
        if _config is None or mtime > _config_mtime:
            with open(AUTH_FILE, 'r') as f:
                _config = json.load(f)
            _config_mtime = mtime
    except FileNotFoundError:
        _config = None
    return _config


def auth_enabled():
    """Check if auth is configured."""
    cfg = _load_config()
    return cfg is not None and (bool(cfg.get('api_keys')) or bool(cfg.get('sso')))


def sso_enabled():
    """Check if SSO is configured."""
    cfg = _load_config()
    return cfg is not None and bool(cfg.get('sso', {}).get('issuer'))


def init_sso(app):
    """Initialize OIDC SSO with Flask app. Call once at startup."""
    global _oauth
    cfg = _load_config()
    if not cfg or not cfg.get('sso', {}).get('issuer'):
        return

    sso = cfg['sso']
    app.secret_key = sso.get('secret_key', os.urandom(32).hex())

    from authlib.integrations.flask_client import OAuth
    _oauth = OAuth(app)
    _oauth.register(
        name='sso',
        client_id=sso['client_id'],
        client_secret=sso.get('client_secret', ''),
        server_metadata_url=sso['issuer'] + '/.well-known/openid-configuration',
        client_kwargs={'scope': 'openid profile email'},
    )


def get_oauth():
    return _oauth


def get_sso_role(userinfo):
    """Map SSO user groups/roles to sheLLaMa role."""
    cfg = _load_config()
    if not cfg:
        return 'viewer'
    sso = cfg.get('sso', {})
    role_mapping = sso.get('role_mapping', {})

    # Check groups claim from various providers:
    # - Azure AD: 'groups' (list of group IDs or names)
    # - Keycloak: 'realm_access.roles' or 'groups'
    # - Authentik: 'groups' (list of group names) or 'ak_proxy.user_attributes.groups'
    user_groups = set()
    user_groups.update(userinfo.get('groups', []))
    realm_access = userinfo.get('realm_access', {})
    user_groups.update(realm_access.get('roles', []))
    user_groups.update(userinfo.get('roles', []))
    # Authentik nested attributes
    ak_proxy = userinfo.get('ak_proxy', {})
    ak_attrs = ak_proxy.get('user_attributes', {})
    user_groups.update(ak_attrs.get('groups', []))

    # Check from highest to lowest privilege
    for role in ['admin', 'user', 'viewer']:
        required_groups = role_mapping.get(role, [])
        if any(g in user_groups for g in required_groups):
            return role

    return sso.get('default_role', 'viewer')


def get_api_key_info(key):
    """Look up an API key, return its config or None."""
    cfg = _load_config()
    if not cfg:
        return None
    return cfg.get('api_keys', {}).get(key)


def check_endpoint_access(role, endpoint):
    """Check if a role can access an endpoint."""
    perms = ROLE_PERMISSIONS.get(role, {})
    allowed = perms.get('endpoints', [])
    if 'all' in allowed:
        return True
    ep = endpoint.lstrip('/')
    return ep in allowed


def check_model_access(key_info, model):
    """Check if an API key can use a specific model."""
    models = key_info.get('models', ['all'])
    if 'all' in models:
        return True
    return model in models


def check_cloud_fallback(key_info):
    """Check if an API key can trigger cloud fallback."""
    role = key_info.get('role', 'viewer')
    if 'cloud_fallback' in key_info:
        return key_info['cloud_fallback']
    return ROLE_PERMISSIONS.get(role, {}).get('cloud_fallback', False)


def require_auth(f):
    """Decorator: require valid API key. Skips if auth not configured."""
    @wraps(f)
    def decorated(*args, **kwargs):
        if not auth_enabled():
            request._shellama_key_info = None
            return f(*args, **kwargs)

        key = request.headers.get('X-API-Key') or request.headers.get('Authorization', '').replace('Bearer ', '') or request.args.get('api_key')

        if not key:
            return jsonify({'error': 'API key required. Set X-API-Key header or Authorization: Bearer <key>'}), 401

        key_info = get_api_key_info(key)
        if not key_info:
            return jsonify({'error': 'Invalid API key'}), 401

        role = key_info.get('role', 'viewer')
        endpoint = request.path

        if not check_endpoint_access(role, endpoint):
            return jsonify({'error': f'Role "{role}" cannot access {endpoint}'}), 403

        model = (request.json or {}).get('model', '') if request.is_json else ''
        if model and not check_model_access(key_info, model):
            return jsonify({'error': f'API key not authorized for model "{model}"'}), 403

        # Rate limiting
        rate_err = _check_rate_limit(key, key_info)
        if rate_err:
            return jsonify({'error': rate_err}), 429

        request._shellama_key_info = key_info
        request._shellama_key = key
        return f(*args, **kwargs)
    return decorated


def require_admin(f):
    """Decorator: require admin role."""
    @wraps(f)
    def decorated(*args, **kwargs):
        if not auth_enabled():
            return f(*args, **kwargs)

        key = request.headers.get('X-API-Key') or request.headers.get('Authorization', '').replace('Bearer ', '') or request.args.get('api_key')
        if not key:
            return jsonify({'error': 'Admin API key required'}), 401

        key_info = get_api_key_info(key)
        if not key_info or key_info.get('role') != 'admin':
            return jsonify({'error': 'Admin access required'}), 403

        request._shellama_key_info = key_info
        return f(*args, **kwargs)
    return decorated


def require_sso(f):
    """Decorator: require SSO login for web pages. Passes through if SSO not configured."""
    @wraps(f)
    def decorated(*args, **kwargs):
        if not sso_enabled():
            request._shellama_sso_user = None
            request._shellama_sso_role = 'admin'  # no SSO = full access
            return f(*args, **kwargs)

        user = session.get('user')
        if not user:
            return redirect('/sso/login')

        request._shellama_sso_user = user
        request._shellama_sso_role = get_sso_role(user)
        return f(*args, **kwargs)
    return decorated


def get_key_name():
    """Get the name of the current API key, or 'anonymous'."""
    info = getattr(request, '_shellama_key_info', None)
    return info.get('name', 'unknown') if info else 'anonymous'


def get_web_role():
    """Get the role for the current web session."""
    return getattr(request, '_shellama_sso_role', 'admin')
