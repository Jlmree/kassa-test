#!/usr/bin/env python3
"""Aanvraagformulier van de website (site/index.html): ontvangt een aanvraag, bewaart hem
en mailt hem door. Draait achter Caddy op 127.0.0.1 (kassa-website.service, zie website.sh).

- Bewaard in $STATE_DIRECTORY/aanvragen.jsonl. IP-adressen gaan er na 30 dagen uit,
  aanvragen na 365 dagen (zie de privacyverklaring).
- Doormailen met het mailaccount uit mail.env ($CREDENTIALS_DIRECTORY, door website.sh mail
  ingesteld). Lukt mailen niet, dan staat de aanvraag er toch: website.sh aanvragen.
- Tegen spam: een verborgen veld dat mensen leeg laten, minstens 3 seconden op de pagina,
  hoogstens 5 aanvragen per uur per adres en 50 per dag in totaal.

  website-aanvraag.py                 de dienst starten
  website-aanvraag.py --test <bestand> een proefmail sturen met het mailaccount uit <bestand>
"""
import json, os, re, smtplib, ssl, sys, threading, time
from email.message import EmailMessage
from email.utils import formatdate, make_msgid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

POORT = int(os.environ.get('WEBSITE_POORT', '8790'))
MAP = os.environ.get('STATE_DIRECTORY', '/var/lib/kassa-website')
BESTAND = os.path.join(MAP, 'aanvragen.jsonl')
MAIL_ENV = os.path.join(os.environ.get('CREDENTIALS_DIRECTORY', '/etc/kassa'), 'mail.env' if 'CREDENTIALS_DIRECTORY' in os.environ else 'website-mail.env')
EMAIL = re.compile(r'^[^\s@<>"\',;]+@[^\s@<>"\',;]+\.[^\s@<>"\',;]+$')
KEUZES = {'server': 'Op jullie server', 'kastje': 'Kastje in de kantine', 'weet niet': 'Weet ik nog niet'}
slot = threading.Lock()
per_adres: dict[str, list[float]] = {}
per_dag: list[float] = []


def mail_config(pad):
    c = {}
    try:
        for regel in open(pad, encoding='utf-8'):
            if '=' in regel:
                k, v = regel.rstrip('\n').split('=', 1)
                c[k] = v
    except OSError:
        pass
    return c if c.get('NAAR') and c.get('SERVER') else None


def versturen(c, onderwerp, tekst, antwoord_aan=None):
    m = EmailMessage()
    m['From'] = f"Bar-kassa website <{c.get('VAN') or c.get('GEBRUIKER')}>"
    m['To'] = c['NAAR']
    m['Subject'] = onderwerp
    m['Date'] = formatdate(localtime=True)
    m['Message-ID'] = make_msgid(domain='kassa')
    if antwoord_aan:
        m['Reply-To'] = antwoord_aan
    m.set_content(tekst)
    poort = int(c.get('POORT') or 587)
    ctx = ssl.create_default_context()
    if poort == 465:
        s = smtplib.SMTP_SSL(c['SERVER'], poort, timeout=20, context=ctx)
    else:
        s = smtplib.SMTP(c['SERVER'], poort, timeout=20)
        s.starttls(context=ctx)
    with s:
        if c.get('GEBRUIKER'):
            s.login(c['GEBRUIKER'], c.get('WACHTWOORD', ''))
        s.send_message(m)


def opruimen_en_bewaren(nieuw):
    """Voegt een aanvraag toe en haalt oude IP-adressen en aanvragen weg."""
    nu = time.time()
    regels = []
    try:
        for r in open(BESTAND, encoding='utf-8'):
            try:
                a = json.loads(r)
            except ValueError:
                continue
            if nu - a.get('ts', 0) > 365 * 86400:
                continue
            if nu - a.get('ts', 0) > 30 * 86400:
                a.pop('ip', None)
            regels.append(a)
    except FileNotFoundError:
        pass
    regels.append(nieuw)
    tmp = BESTAND + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        for a in regels:
            f.write(json.dumps(a, ensure_ascii=False) + '\n')
    os.chmod(tmp, 0o600)
    os.replace(tmp, BESTAND)


def te_veel(ip):
    nu = time.time()
    with slot:
        per_dag[:] = [t for t in per_dag if nu - t < 86400]
        lijst = [t for t in per_adres.get(ip, []) if nu - t < 3600]
        per_adres[ip] = lijst
        if len(lijst) >= 5 or len(per_dag) >= 50:
            return True
        lijst.append(nu)
        per_dag.append(nu)
        return False


def schoon(v, n):
    """Tekst uit het formulier: geen stuurtekens, hoogstens n tekens."""
    return re.sub(r'[\x00-\x08\x0b-\x1f\x7f]', '', str(v or '')).strip()[:n]


class Handler(BaseHTTPRequestHandler):
    server_version = 'kassa'
    sys_version = ''

    def antwoord(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):  # geen IP-adressen in het journal
        pass

    def do_GET(self):
        self.antwoord(405, {'fout': 'Alleen versturen kan hier.'})

    def do_POST(self):
        if self.path.split('?')[0].rstrip('/') != '/aanvraag':
            return self.antwoord(404, {'fout': 'Niet gevonden.'})
        lengte = int(self.headers.get('Content-Length') or 0)
        if lengte <= 0 or lengte > 16384:
            return self.antwoord(413, {'fout': 'De aanvraag is te lang.'})
        try:
            d = json.loads(self.rfile.read(lengte))
            assert isinstance(d, dict)
        except Exception:
            return self.antwoord(400, {'fout': 'De aanvraag kwam niet goed aan.'})
        ip = (self.headers.get('X-Forwarded-For') or self.client_address[0]).split(',')[0].strip()

        # Robots vullen het verborgen veld in of versturen meteen: doen alsof het gelukt is.
        if schoon(d.get('website'), 200) or not isinstance(d.get('seconden'), (int, float)) or d['seconden'] < 3:
            return self.antwoord(200, {'ok': True})
        a = {
            'ts': time.time(), 'tijd': time.strftime('%Y-%m-%d %H:%M'), 'ip': ip,
            'naam': schoon(d.get('naam'), 80), 'club': schoon(d.get('club'), 120),
            'email': schoon(d.get('email'), 120), 'telefoon': schoon(d.get('telefoon'), 30),
            'keus': d.get('keus') if d.get('keus') in KEUZES else 'weet niet',
            'bericht': schoon(d.get('bericht'), 2000),
        }
        if not a['naam'] or not a['club']:
            return self.antwoord(400, {'fout': 'Vul je naam en de naam van de vereniging of kantine in.'})
        if not EMAIL.match(a['email']):
            return self.antwoord(400, {'fout': 'Vul een geldig e-mailadres in.'})
        if te_veel(ip):
            return self.antwoord(429, {'fout': 'Er zijn net veel aanvragen binnengekomen.'})

        with slot:
            opruimen_en_bewaren(a)
        c = mail_config(MAIL_ENV)
        if c:
            tekst = (f"Nieuwe aanvraag via de website ({a['tijd']})\n\n"
                     f"Naam:      {a['naam']}\nKantine:   {a['club']}\nE-mail:    {a['email']}\n"
                     f"Telefoon:  {a['telefoon'] or '-'}\nInteresse: {KEUZES[a['keus']]}\n\n{a['bericht'] or '(geen bericht)'}\n\n"
                     "Beantwoorden: gewoon op deze mail reageren.\n")
            try:
                versturen(c, f"Aanvraag Bar-kassa: {a['club']}"[:150], tekst, a['email'])
            except Exception as e:  # de aanvraag is bewaard; website.sh aanvragen laat hem zien
                print(f'Doormailen mislukt: {type(e).__name__}: {e}', file=sys.stderr, flush=True)
        self.antwoord(200, {'ok': True})


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--test':
        c = mail_config(sys.argv[2])
        if not c:
            sys.exit('Er is nog geen mailaccount ingesteld.')
        try:
            versturen(c, 'Proefmail van de Bar-kassa website',
                      'Dit is een proefmail. Aanvragen via het formulier op de website komen voortaan op dit adres binnen.\n')
        except smtplib.SMTPAuthenticationError:
            sys.exit('De mailserver weigert de gebruikersnaam of het wachtwoord.')
        except (OSError, smtplib.SMTPException) as e:
            sys.exit(f'Versturen mislukt: {e}')
        print(f"Proefmail verstuurd naar {c['NAAR']}.")
        sys.exit(0)
    os.makedirs(MAP, exist_ok=True)
    ThreadingHTTPServer(('127.0.0.1', POORT), Handler).serve_forever()
