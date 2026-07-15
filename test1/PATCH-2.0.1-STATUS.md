# EVS — статус работы (патч 2.0.1), где остановились

Дата: 2026-07-08. Ветка: `desktop`. Всё ниже — на этой машине, синхронизировать с
GitHub (`kekw2077/mirai`, ветка `desktop`).

## Контекст

Большой патч из 3 ТЗ (STT-движки, шумодав/модели/голоса/GPU/игр.режим/микрофоны,
тема/окна/виджет/холодный старт) — **код полностью готов и выпущен как EVS 2.0.0**
(коммит `338a94b`, релиз `desktop-v2.0.0`, компонент сайдкара v8).

После установки 2.0.0 пользователь нашёл баги. Идёт **патч 2.0.1**.

## Найденные баги (2.0.0) и их причины

1. **GigaAM / денойз / Piper падают** («light denoise model not found», у GigaAM в
   логе `The requested API version [24] is not available ... Current ORT Version is
   1.17.1`). ПРИЧИНА: **onefile-сборка сайдкара сваливает все DLL в одну папку**, а
   sherpa-onnx и faster-whisper несут РАЗНЫЕ `onnxruntime.dll` (1.24.4 vs 1.27.0) →
   грузится не тот → sherpa не создаёт сессии. Непостоянно (зависит от порядка
   загрузки DLL — иногда GigaAM работает, иногда нет).
   ФИКС: собирать сайдкар как **--onedir + zip** (у каждого пакета своя папка DLL).
2. **Whisper: «Unable to open file 'model.bin'»** при переключении движков / на
   старте. ПРИЧИНА: жадный прогрев стартует ровно когда модель ещё до-скачивается
   (гонка). ФИКС: ретрай загрузки в `_ensure_model` (4 попытки × 2с).
3. **Разъехалась сетка настроек** (большая пустая дыра). ПРИЧИНА: старый `Wrap`
   парными рядами + пустые GPU-карточки (`SizedBox.shrink`) → дыра высотой соседней
   карточки. ФИКС: настоящий **двухколоночный masonry** (`_cardMasonry`).
4. **Бейдж «Подключён · Whisper»** всегда Whisper. ФИКС: показывает активный движок
   (`sttSidecarEngine`).
5. **Путаница «Движок» vs «Модель»** (GigaAM только в «Модель», в «Движке» его нет).
   ФИКС: тумблер «Windows STT | Локальный (EVS)»; карточки Whisper/GigaAM показываются
   только под локальным движком; «Модель распознавания» → «Локальный движок».
6. **Виджет-волна с резкими квадратными краями.** ФИКС: `fadeEdges` (радиальный
   виньет) на `EvsWaveViz`, включён на домашнем hero.

## Что уже СДЕЛАНО в коде (НЕ закоммичено — синхронизировать!)

Изменённые файлы (working tree):
- `test1/lib/main.dart` — фиксы 3,4,5,6 (masonry, бейдж, движок/модель UI, fadeEdges).
- `test1/sidecar/stt_engine.py` — фикс 2 (ретрай `_ensure_model`).
- `test1/sidecar/build_exe.ps1` — фикс 1 (--onedir + zip, components.json archive).
- `test1/PATCH-2.0.1-STATUS.md` — этот файл.

`flutter analyze` — чисто. Sidecar `py_compile` — ок.

## Что ОСТАЛОСЬ доделать для выпуска 2.0.1

1. **Синхронизировать working tree с git** (закоммитить+запушить перечисленные
   выше файлы). На этой машине **git не установлен** (есть только GitHub CLI) — Bash-
   окружение с git отключилось. Нужен git (`winget install Git.Git`) ИЛИ выполнить
   вручную:
   ```
   git add test1/lib/main.dart test1/sidecar/stt_engine.py test1/sidecar/build_exe.ps1 test1/PATCH-2.0.1-STATUS.md
   git commit -m "EVS 2.0.1 fixes: sidecar onedir(onnxruntime), whisper retry, settings masonry, engine/model UX, wave edges"
   git push origin desktop
   ```
2. **Пересобрать сайдкар v9 (onedir+zip):**
   ```
   cd test1\sidecar
   .\build_exe.ps1 -ComponentVersion 9
   ```
   Проверить фрозен-zip: распаковать, запустить `evs_sidecar.exe`, убедиться что в
   `ready.capabilities` piper/gigaam создают сессии (нет ORT-ошибки). Затем:
   ```
   gh release upload desktop-components dist\evs_sidecar.zip --repo kekw2077/mirai --clobber
   gh release delete-asset desktop-components evs_sidecar.exe --repo kekw2077/mirai --yes   # старый onefile больше не нужен
   ```
   Закоммитить обновлённый `test1/dist/components.json` (sidecar → archive v9).
3. **Выпустить приложение 2.0.1:**
   - `pubspec.yaml`: `2.0.0+19` → `2.0.1+20`.
   - Добавить запись в `kChangelog` (main.dart) + `<item>` в `test1/dist/appcast.xml`
     (кратко: что починено).
   - `flutter build windows --release` (сверить FileVersion exe == 2.0.1).
   - Инсталлятор: `& "C:\Users\korne\AppData\Local\Programs\Inno Setup 6\ISCC.exe" /DAppVersion=2.0.1 dist\installer.iss` → `dist\out\EVS-Setup-2.0.1.exe`.
   - Подпись: `.\dist\sign_update.ps1 .\dist\out\EVS-Setup-2.0.1.exe` (даёт length+sha256+dsaSignature) → вписать в новый `<item>` appcast.
   - `gh release create desktop-v2.0.1 dist\out\EVS-Setup-2.0.1.exe --repo kekw2077/mirai --title "EVS 2.0.1" --notes "..."`.
   - commit pubspec+main.dart+appcast+components.json, `git push origin desktop`.

## Тулинг (всё на месте)
- ISCC: `C:\Users\korne\AppData\Local\Programs\Inno Setup 6\ISCC.exe`
- DSA-ключ: `test1/dsa_priv.pem` (git-ignored)
- openssl: был в Git-Bash (`/mingw64/bin/openssl`) — при отсутствии git-bash взять из
  установки Git или указать `-OpenSsl`.
- gh: `C:\Program Files\GitHub CLI\` (авторизован как kekw2077).
- Sidecar venv: `test1/sidecar/.venv` (Python 3.12), pyinstaller + sherpa-onnx +
  nvidia-ml-py установлены.

## Ещё не проверено вживую (нужно железо пользователя)
GPU/CUDA (RTX 3060), VRAM-триггер игрового режима, 2 физических микрофона +
арбитраж, NVIDIA Broadcast. Логика покрыта юнит-тестами; проверить на ПК.
