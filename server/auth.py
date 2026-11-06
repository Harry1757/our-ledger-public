import hashlib

WEB_SESSION_SECONDS = 30 * 24 * 60 * 60


def digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


class Unauthorized(Exception):
    pass
