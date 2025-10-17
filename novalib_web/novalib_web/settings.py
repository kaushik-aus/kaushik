import os
from pathlib import Path
import sys
import re

BASE_DIR = Path(__file__).resolve().parent.parent

MEDIA_URL = '/media/'
MEDIA_ROOT = BASE_DIR / 'media'

SECRET_KEY = os.environ.get('DJANGO_SECRET_KEY', 'django-insecure-your-secret-key-here')
DEBUG = os.environ.get('DJANGO_DEBUG', 'True') == 'True'
PYTHONANYWHERE_DOMAIN = os.environ.get('PYTHONANYWHERE_DOMAIN', 'voidnova.pythonanywhere.com')

ALLOWED_HOSTS = ['localhost', '127.0.0.1', "voidnova.pythonanywhere.com","10.42.204.189"]
if os.environ.get('DJANGO_ALLOWED_HOSTS'):
    ALLOWED_HOSTS.extend(os.environ.get('DJANGO_ALLOWED_HOSTS').split(','))
if DEBUG:
    ALLOWED_HOSTS.append('*')
    ALLOWED_HOSTS.append('192.168.197.149')

INSTALLED_APPS = [
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'rest_framework',
    'novalib',
    'corsheaders',
]

MIDDLEWARE = [
    # normalize duplicate slashes (e.g. //api/... -> /api/). Must run very early.
    'novalib_web.settings.StripDuplicateSlashesMiddleware',
    'django.middleware.security.SecurityMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
    'corsheaders.middleware.CorsMiddleware',
]

ROOT_URLCONF = 'novalib_web.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [BASE_DIR / "templates"],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = 'novalib_web.wsgi.application'

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.mysql',
        'NAME': "novalib_db",  
        'USER': "root",        
        'PASSWORD': "MyStrongPass123!",
        'HOST': "localhost",         
        'PORT': '3306',
        'OPTIONS': {
            'init_command': "SET sql_mode='STRICT_TRANS_TABLES'",
        },
    }
}


AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator'},
    {'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator'},
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator'},
]

LANGUAGE_CODE = 'en-us'
TIME_ZONE = 'Asia/Kolkata'
USE_I18N = True
USE_TZ = True

# --- STATIC FILES CONFIGURATION ---
STATIC_URL = '/static/'
STATIC_ROOT = os.path.join(BASE_DIR, 'static')
# Do NOT set STATICFILES_DIRS if you only use app/static folders and STATIC_ROOT.
# If you have other folders with static files (like 'assets'), you could add:
# STATICFILES_DIRS = [os.path.join(BASE_DIR, 'assets'),]

DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'

REST_FRAMEWORK = {
    'DEFAULT_PERMISSION_CLASSES': ['rest_framework.permissions.AllowAny'],
    'DEFAULT_RENDERER_CLASSES': ['rest_framework.renderers.JSONRenderer'],
}

SESSION_ENGINE = 'django.contrib.sessions.backends.db'
SESSION_COOKIE_AGE = 600  # 10 minutes

EMAIL_BACKEND = 'django.core.mail.backends.smtp.EmailBackend'
EMAIL_HOST = 'smtp.gmail.com'
EMAIL_PORT = 587
EMAIL_USE_TLS = True
EMAIL_HOST_USER = os.environ.get('EMAIL_HOST_USER', 'sayan.kumar.roy@aus.ac.in')
EMAIL_HOST_PASSWORD = os.environ.get('EMAIL_HOST_PASSWORD', 'dhsa hntb ency rxzx')

CORS_ALLOW_ALL_ORIGINS = DEBUG
if not DEBUG:
    CORS_ALLOWED_ORIGINS = [f"https://{PYTHONANYWHERE_DOMAIN}"]

# Let CommonMiddleware append slashes when appropriate
APPEND_SLASH = True

# Middleware implemented inline to avoid adding a new file.
class StripDuplicateSlashesMiddleware:
    """
    Robustly collapse multiple consecutive slashes in PATH_INFO and related WSGI keys.
    This addresses requests like "//api/send-otp/" and also normalizes RAW_URI / REQUEST_URI
    while preserving query strings.
    """
    def __init__(self, get_response):
        self.get_response = get_response

    def _collapse(self, s: str) -> str:
        if not s:
            return s
        return re.sub(r'/{2,}', '/', s)

    def __call__(self, request):
        meta = request.META
        path = meta.get('PATH_INFO', '') or ''
        new_path = self._collapse(path)
        # Ensure path starts with exactly one slash
        if not new_path.startswith('/'):
            new_path = '/' + new_path

        if new_path != path:
            meta['PATH_INFO'] = new_path

        # Normalize REQUEST_URI / RAW_URI which may include query string
        for key in ('REQUEST_URI', 'RAW_URI'):
            raw = meta.get(key)
            if raw:
                # split off query string if present
                parts = raw.split('?', 1)
                parts[0] = self._collapse(parts[0])
                meta[key] = parts[0] + ('?' + parts[1] if len(parts) == 2 else '')

        # Also normalize other possible keys
        for key in ('ORIG_PATH_INFO', 'RAW_PATH_INFO'):
            if key in meta and meta[key]:
                meta[key] = self._collapse(meta[key])

        return self.get_response(request)
