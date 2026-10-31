# Contrat d'API des serveurs IA de Portail

Portail (à partir de la v1.8.0) parle à un serveur IA auto-hébergé par ce contrat, **compatible OpenAI** : le serveur
maison (`https://atelier.mawena.cloud`), mais aussi Ollama, vLLM ou LocalAI. Portail ne demande que les routes
ci-dessous ; tout le reste de l'API d'OpenAI est ignoré.

- **Transport** : HTTP/1.1 ou HTTP/2, `https://` recommandé ; `http://` accepté (serveur local, Ollama). Vers une
  adresse qui n'est pas locale, Portail avertit que la clé et les conversations passent en clair sur Internet.
- **Authentification** : en-tête `Authorization: Bearer <clé>` sur **toutes** les routes, s'il y a une clé. Sans clé
  enregistrée (Ollama), aucun en-tête n'est envoyé. `GET /health` peut être publique (c'est le cas du serveur maison).
- **Corps** : JSON en UTF-8, `Content-Type: application/json`.
- **Délais de Portail** : connexion 10 s ; réponse sans flux 120 s ; en flux, 60 s au plus sans aucun octet ;
  `GET /health` 5 s.

## `GET /health` (facultative)

```http
GET /health
```

```json
{ "status": "ok", "version": "0.1.0" }
```

Absente (404, cas d'Ollama), Portail déduit l'état de `GET /v1/models` : 200 en ligne, 401 ou 403 clé refusée.
Une réponse 200 sans JSON (vLLM) compte « en ligne », version inconnue.

## `GET /v1/models`

```json
{
  "object": "list",
  "data": [
    { "id": "qwen2.5:7b", "object": "model", "owned_by": "atelier" },
    { "id": "llama3.1:8b", "object": "model" }
  ]
}
```

`owned_by` est facultatif. Portail montre `id` tel quel, dans l'ordre reçu.

## `POST /v1/chat/completions`

Requête :

```json
{
  "model": "qwen2.5:7b",
  "messages": [
    { "role": "system", "content": "Réponds en français." },
    { "role": "user", "content": "Bonjour" },
    { "role": "assistant", "content": "Bonjour ! Que puis-je faire pour vous ?" },
    { "role": "user", "content": "Explique-moi SSE en une phrase." }
  ],
  "stream": true,
  "temperature": 0.7,
  "max_tokens": 512
}
```

`temperature` et `max_tokens` ne sont envoyés que s'ils ont été choisis (sinon, valeurs du serveur). Portail envoie au
plus les **200** messages les plus récents, le prompt système toujours gardé.

### Sans flux (`"stream": false`)

```json
{
  "choices": [
    { "index": 0, "message": { "role": "assistant", "content": "SSE envoie des événements…" }, "finish_reason": "stop" }
  ],
  "usage": { "prompt_tokens": 42, "completion_tokens": 12, "total_tokens": 54 }
}
```

`usage` est facultatif. Utilisé par les automatisations.

### En flux (`"stream": true`)

Réponse `Content-Type: text/event-stream`, un événement par ligne `data:` suivie d'une ligne vide :

```text
data: {"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{"content":"SSE "},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{"content":"envoie…"},"finish_reason":null}]}

data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: [DONE]

```

- Le flux se termine par `data: [DONE]`. Une connexion fermée sans `[DONE]` donne une réponse **interrompue** (le
  texte reçu est gardé).
- Une erreur en cours de flux arrive en `data: {"error":{"message":"…"}}` : le texte reçu est gardé, la réponse est
  marquée en échec avec ce message.
- Les lignes de commentaire (`: …`), les champs `event:`, `id:`, `retry:`, les fins de ligne `\r\n` et les événements
  sans `choices` ou sans `delta.content` sont acceptés et ignorés.
- Un éventuel événement final avec `usage` est accepté.

## `POST /v1/embeddings` (facultative)

```json
{ "model": "nomic-embed-text", "input": ["Bonjour", "Au revoir"] }
```

```json
{ "object": "list", "data": [ { "index": 0, "embedding": [0.012, -0.034] }, { "index": 1, "embedding": [0.2, 0.1] } ] }
```

Prévue dans l'interface de Portail pour une recherche sémantique future ; aucun écran ne s'en sert en v1.8.0.

## Voix de narration (facultatives, à partir de la v1.12.0)

Extension maison, hors API d'OpenAI sauf `POST /v1/audio/speech`. Un serveur qui ne les a pas (404) masque le module
« Voix » de Portail. Conception : § 28 de la spec. **Exclu par décision** : toute transformation de voix en direct et
toute création de voix à partir d'un fichier importé ; le serveur n'expose donc aucune route de conversion de voix.

### `GET /v1/voices`

```json
{ "object": "list", "data": [ { "id": "voix_7f3a", "name": "Charles", "created": 1793433600, "model": "chatterbox-multilingual" } ] }
```

### `POST /v1/voices`

`multipart/form-data`, tous les champs obligatoires :

| Champ | Contenu |
|---|---|
| `name` | Nom affiché de la personne |
| `consent_text` | Texte de consentement affiché, avec le nom, le code à 6 chiffres et la date |
| `consent_code` | Le code aléatoire tiré par Portail pour cette session |
| `consent_audio` | La lecture du texte de consentement (WAV ou M4A, enregistrée par le micro) |
| `sample_audio` | L'échantillon de voix (environ 1 min), même session |

Réponse 201 : l'objet voix, comme dans la liste. Le serveur garde le consentement (audio, texte, code, horodatage) avec
la voix. **422** `consent_rejected` si le consentement retranscrit ne contient pas le code ou le nom ; **422**
`sample_quality` si l'échantillon est trop court, trop faible ou saturé (le message dit lequel).

### `DELETE /v1/voices/{id}`

204. Supprime l'échantillon, le consentement et l'empreinte vocale. Une voix supprimée n'est plus utilisable.

### `POST /v1/audio/speech`

Compatible OpenAI :

```json
{ "model": "chatterbox-multilingual", "input": "Bonjour et bienvenue.", "voice": "voix_7f3a", "response_format": "mp3", "speed": 1.0 }
```

Réponse : le fichier audio (`audio/mpeg` ou `audio/wav`). `input` : 5 000 caractères au plus par appel (Portail découpe
au-delà, aux fins de phrase). Le filigrane inaudible éventuel est posé par le serveur ; Portail ajoute lui-même le
suffixe `-voix-synthese` et la métadonnée « Voix de synthèse générée par Portail ».

## Erreurs

Codes 400, 401, 403, 404, 429, 500, 503, corps :

```json
{ "error": { "message": "Clé API invalide.", "type": "auth_error", "code": "invalid_api_key" } }
```

`type` et `code` sont facultatifs ; `code` peut être un nombre ou un texte (le serveur maison envoie `"401"`).
Portail montre un message français qui dit quoi faire, et le message du serveur tel quel en dessous :

| Code | Message de Portail |
|------|--------------------|
| 401 | Clé API refusée : vérifiez la clé enregistrée pour ce serveur |
| 403 | Accès refusé par le serveur : cette clé n'a pas le droit de faire cela |
| 404 sur un modèle | Modèle introuvable sur ce serveur : choisissez-en un autre |
| 429 | Le serveur est surchargé ou la limite de requêtes est atteinte : réessayez plus tard |
| 500, 502, 503, 504 | Le serveur a rencontré une erreur : réessayez plus tard |

Un 401 n'est jamais relancé automatiquement.

## Écarts connus des serveurs compatibles

| Serveur | Écarts |
|---------|--------|
| **Serveur maison** (`atelier.mawena.cloud`, proxy LiteLLM) | `/health` publique ; erreur 401 sans clé : `{"error":{"message":"Authentication Error, No api key passed in.","type":"auth_error","param":"None","code":"401"}}` (champ `param` en plus, `code` en texte). |
| **Ollama** (`http://hôte:11434`) | Pas de `/health` (404 ; `GET /` répond « Ollama is running ») ; aucune clé exigée (un en-tête `Authorization` est ignoré) ; `/v1/embeddings` présent avec un modèle d'embeddings ; `usage` en flux seulement avec `stream_options`. |
| **vLLM** | `GET /health` rend 200 **sans corps** ; clé seulement si lancé avec `--api-key` ; anciennes versions : erreur au premier niveau (`{"object":"error","message":"…","type":"…","code":400}`), que Portail lit aussi. |
| **LocalAI** | Santé sur `/readyz` et `/healthz` (pas de `/health` : 404, état déduit de `/v1/models`) ; clé facultative (`API_KEY`) ; erreurs `{"error":{"code":…,"message":…,"type":…}}`. |

## Outils

- `tools/ia/serveur-essai.py` : serveur d'essai (bibliothèque standard de Python), clé `essai-portail`, modèles
  `essai-court`, `essai-long` (2 000 morceaux numérotés), `essai-erreur` (erreur au milieu du flux), `essai-lent`
  (70 s avant le premier octet) ; `--port`, `--reverse` (`adb reverse`, `ADB_SERIAL`), `--comme-ollama` (sans
  `/health` ni clé).
- `tools/ia/contrat_test.py URL [CLÉ] [--modele M]` : vérifie un serveur contre ce contrat ; sans clé face à un
  serveur qui en exige une, vérifie seulement la santé et le format du 401.

Constat du 2026-10-25 sur `https://atelier.mawena.cloud`, sans clé : `GET /health` → `{"status":"ok","version":"0.1.0"}`,
`GET /v1/models` → 401 au format ci-dessus ; `contrat_test.py` : contrat respecté.
