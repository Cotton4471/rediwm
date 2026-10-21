# Translating RediWM

RediWM uses English source messages and compiled PO catalogs. The initial
languages are Spanish (`es`), Brazilian Portuguese (`pt_BR`), German (`de`),
French (`fr`) and Russian (`ru`). `pt` falls back to `pt_BR`; regional tags
fall back to their language. English and unknown languages use the source text.
`qps` is an expanded pseudo-language for layout testing, hidden from the picker.

## Status and review

All five initial catalogs are **machine drafts that have not had native-speaker
review**. The maintainer removed the `fuzzy` flags on 2026-10-22, so every
translated entry now reaches the UI, installed desktop files and polkit policy.
The picker lists each catalog language by name with no status suffix, and
choosing one applies it immediately. Untranslated messages still show English.

| Catalog | Native name | Address | Review status |
| --- | --- | --- | --- |
| es | Español | tú; neutral vocabulary, no voseo | Draft; native and screenshot review pending |
| pt_BR | Português (Brasil) | você | Draft; native and screenshot review pending |
| de | Deutsch | du | Draft; native and screenshot review pending |
| fr | Français | vous; infinitive button labels | Draft; native and screenshot review pending |
| ru | Русский | вы | Draft; native and screenshot review pending |

Run `zig build i18n-check` for current coverage. The picker lists catalog
languages even without a generated system locale. A native reviewer should
re-add `fuzzy` to any entry they find wrong. Set `X-RediWM-Reviewed: yes` only
after the whole catalog, screenshots, and the manual security-dialog checklist
have been reviewed, and record the reviewer's name, date and revision here. No
such review has happened yet.

The UI catalog needs no installed glibc locale. Dates, sorting and other apps
may need one: enable the suggested `xx_XX.UTF-8` locale in the distribution's
locale settings. RediWM does not edit system locale files or run privileged
locale-generation commands.

## Workflow

1. Run `zig build i18n-extract` after changing user-facing source strings.
2. Translate `po/<tag>.po` with a PO editor. Preserve `msgctxt`, English
   `msgid`, named `{placeholders}`, strftime directives in the `date` context,
   and desktop-entry keyword semicolons. Put draft translations behind `fuzzy`.
3. Run `zig build i18n-check` and `zig build i18n-lint`. The checker rejects
   stale IDs, placeholder mismatches, malformed plurals and French U+202F.
   Use U+00A0, the no-break space supported by the bundled font, in French.
4. Build with `zig build`. Select `[region] language = "<tag>"` in a scratch
   configuration. For draft review, remove `fuzzy` in a separate local review
   copy; do not silently publish that copy as reviewed.
5. Run `python3 scripts/i18n-screens.py <tag> --out /tmp/rediwm-<tag>-review`.
   It starts an isolated headless session, captures the shell, Settings and
   apps, and writes a review report of text wider than its widget. Inspect
   ellipsized labels, long unbroken words and dialogs at normal and fractional
   scale. Run the same walk for `qps` after UI changes.
6. Review lock, greeter and authentication screens through the existing
   isolated lock/polkit fixtures and a test login. Production policy deliberately
   denies pixel-reading IPC while locked; the screenshot walk does not bypass
   it. Security buttons need a second review for meaning and action.
7. Build Debug and ReleaseSafe, run `zig build test`, `python3 tests/i18n.py`,
   and affected integration suites. Submit the PO and review record in a PR.

New catalogs may supply `X-RediWM-Native-Name`, `X-RediWM-Locale` and
`X-RediWM-Reviewed` headers. The build discovers `.po` files automatically.
A new plural family needs a rule in `src/i18n/mod.zig` and the matching compiler
validation in `tools/i18n.zig`; add examples to the tests. Review metadata is
not evidence by itself: link the actual review in this document.

## Source conventions

Use `i18n.tr("Cancel")`, `trc("menu", "Open")` or
`trn("{n} item", "{n} items", n)`. `i18n.fmt`/`allocPrint` substitute named
arguments and allow reordering. Preformat numbers when precision or units need
special handling. `fmtZ` and `trZ` serve APIs requiring a trailing NUL.
`i18n.msg("Label")` stores a prehashed message in a static descriptor;
`.get()` resolves it when building UI. Never retain a slice to a local array
of runtime translations in a widget tree.

Widget names, IPC/config keys, filesystem names, commands, MIME values,
logs and external messages are not translated. Add `// i18n:` comments above
ambiguous UI messages; they are copied to the template. `po/lint-files` lists
files checked for untranslated UI literals; `// i18n: raw` documents an
intentional exception. Broaden that list with each reviewed conversion.

Catalog lookup never reads files, changes the process locale, allocates,
hashes a source string at runtime, or starts a timer. Language reload rebuilds
shell UI; app clients resolve the launch environment and change on relaunch.
Root helpers keep returning codes, with wording owned by the unprivileged UI.

## Working glossary

These terms are a starting point for reviewers. Keep RediWM and protocol/
product names intact; translate app names as ordinary words. Prefer a short,
clear label over a literal English construction.

| English | es | pt_BR | de | fr | ru |
| --- | --- | --- | --- | --- | --- |
| Window | Ventana | Janela | Fenster | Fenêtre | Окно |
| Workspace | Espacio de trabajo | Área de trabalho | Arbeitsfläche | Espace de travail | Рабочее пространство |
| Desktop | Escritorio | Área de trabalho | Schreibtisch | Bureau | Рабочий стол |
| Dock | Dock | Dock | Dock | Dock | Док |
| Taskbar | Barra de tareas | Barra de tarefas | Taskleiste | Barre des tâches | Панель задач |
| Tile | Mosaico | Lado a lado | Kachel | Mosaïque | Плитка |
| Lock screen | Pantalla de bloqueo | Tela de bloqueio | Sperrbildschirm | Écran de verrouillage | Экран блокировки |
| Control Center | Centro de control | Central de configurações | Kontrollzentrum | Centre de contrôle | Центр управления |
| Settings | Configuración | Configurações | Einstellungen | Paramètres | Настройки |
| Files | Archivos | Arquivos | Dateien | Fichiers | Файлы |
| Images | Imágenes | Imagens | Bilder | Images | Изображения |
| Editor | Editor | Editor | Editor | Éditeur | Редактор |
| Calculator | Calculadora | Calculadora | Rechner | Calculatrice | Калькулятор |
| System Monitor | Monitor del sistema | Monitor do sistema | Systemmonitor | Moniteur système | Системный монитор |
| Transfers | Transferencias | Transferências | Übertragungen | Transferts | Передачи |
| File | Archivo | Arquivo | Datei | Fichier | Файл |
| Folder | Carpeta | Pasta | Ordner | Dossier | Папка |
| Home | Carpeta personal | Pasta pessoal | Persönlicher Ordner | Dossier personnel | Домашняя папка |
| Trash | Papelera | Lixeira | Papierkorb | Corbeille | Корзина |
| Open | Abrir | Abrir | Öffnen | Ouvrir | Открыть |
| Close | Cerrar | Fechar | Schließen | Fermer | Закрыть |
| Save | Guardar | Salvar | Speichern | Enregistrer | Сохранить |
| Save As | Guardar como | Salvar como | Speichern unter | Enregistrer sous | Сохранить как |
| Cancel | Cancelar | Cancelar | Abbrechen | Annuler | Отмена |
| Apply | Aplicar | Aplicar | Anwenden | Appliquer | Применить |
| Delete | Eliminar | Excluir | Löschen | Supprimer | Удалить |
| Remove | Quitar | Remover | Entfernen | Retirer | Убрать |
| Discard | Descartar | Descartar | Verwerfen | Abandonner | Отбросить |
| Rename | Cambiar nombre | Renomear | Umbenennen | Renommer | Переименовать |
| Copy | Copiar | Copiar | Kopieren | Copier | Копировать |
| Cut | Cortar | Recortar | Ausschneiden | Couper | Вырезать |
| Paste | Pegar | Colar | Einfügen | Coller | Вставить |
| Undo | Deshacer | Desfazer | Rückgängig | Annuler l’action | Отменить действие |
| Search | Buscar | Pesquisar | Suchen | Rechercher | Поиск |
| Filter | Filtrar | Filtrar | Filtern | Filtrer | Фильтр |
| Sort | Ordenar | Ordenar | Sortieren | Trier | Сортировка |
| Name | Nombre | Nome | Name | Nom | Имя |
| Size | Tamaño | Tamanho | Größe | Taille | Размер |
| Modified | Modificado | Modificado | Geändert | Modifié | Изменён |
| Properties | Propiedades | Propriedades | Eigenschaften | Propriétés | Свойства |
| Permissions | Permisos | Permissões | Berechtigungen | Permissions | Права доступа |
| User | Usuario | Usuário | Benutzer | Utilisateur | Пользователь |
| Password | Contraseña | Senha | Passwort | Mot de passe | Пароль |
| Authenticate | Autenticar | Autenticar | Authentifizieren | S’authentifier | Подтвердить личность |
| Lock | Bloquear | Bloquear | Sperren | Verrouiller | Заблокировать |
| Unlock | Desbloquear | Desbloquear | Entsperren | Déverrouiller | Разблокировать |
| Log Out | Cerrar sesión | Sair da sessão | Abmelden | Fermer la session | Выйти из системы |
| Restart | Reiniciar | Reiniciar | Neustarten | Redémarrer | Перезагрузить |
| Suspend | Suspender | Suspender | Bereitschaft | Mettre en veille | Приостановить |
| Power Off | Apagar | Desligar | Ausschalten | Éteindre | Выключить |
| Network | Red | Rede | Netzwerk | Réseau | Сеть |
| Connect | Conectar | Conectar | Verbinden | Connecter | Подключить |
| Disconnect | Desconectar | Desconectar | Trennen | Déconnecter | Отключить |
| Display | Pantalla | Tela | Bildschirm | Écran | Экран |
| Sound | Sonido | Som | Klang | Son | Звук |
| Volume | Volumen | Volume | Lautstärke | Volume | Громкость |
| Keyboard | Teclado | Teclado | Tastatur | Clavier | Клавиатура |
| Shortcut | Atajo de teclado | Atalho de teclado | Tastenkombination | Raccourci clavier | Сочетание клавиш |
| Language | Idioma | Idioma | Sprache | Langue | Язык |
| Region | Región | Região | Region | Région | Регион |
| Time zone | Zona horaria | Fuso horário | Zeitzone | Fuseau horaire | Часовой пояс |
| Printer | Impresora | Impressora | Drucker | Imprimante | Принтер |
| Print | Imprimir | Imprimir | Drucken | Imprimer | Печать |
| Queue | Cola | Fila | Warteschlange | File d’attente | Очередь |
| Notifications | Notificaciones | Notificações | Benachrichtigungen | Notifications | Уведомления |

Integer plural examples: `es`/`de`: 1 versus 0/2; `pt_BR`/`fr`: 0/1 versus
2; `ru`: 1/21, 2/22, 5/11/12/25/111. Check each `trn` entry in all forms,
especially Russian few. French uses U+00A0 before `:;!?` and within guillemets.
