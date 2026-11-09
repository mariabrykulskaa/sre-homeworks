'use strict';

const STATUS_LABELS = {
  todo: 'К работе',
  in_progress: 'В работе',
  done: 'Готово',
};

const state = {
  projects: [],
  projectsTotal: 0,
  tasks: [],
  tasksTotal: 0,
  tasksLoading: false,
  tasksError: false,
  currentProjectId: null,
  statusFilter: '',
  tasksRequestSeq: 0,
  projectsRequestSeq: 0,
};

// Страница не делает пагинацию, поэтому явно просим максимум, который отдаёт API.
const LIST_LIMIT = 500;

const $ = (id) => document.getElementById(id);

// ---------- API ----------

const REQUEST_TIMEOUT_MS = 15_000;

async function request(path, options = {}) {
  let res;
  try {
    res = await fetch(path, {
      // Таймаут обязателен: повисший запрос иначе навсегда оставит
      // кнопку «Сохранить» заблокированной (см. guardSubmit).
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      headers: options.body ? { 'Content-Type': 'application/json' } : undefined,
      ...options,
    });
  } catch (err) {
    if (err?.name === 'TimeoutError' || err?.name === 'AbortError') {
      throw new Error('Сервер не ответил вовремя, попробуйте ещё раз');
    }
    throw new Error('Нет соединения с сервером');
  }
  if (res.status === 204) return null;
  let payload = null;
  try {
    payload = await res.json();
  } catch {
    // тело не JSON — оставляем null
  }
  if (!res.ok) {
    throw new Error(payload?.error ?? `Ошибка запроса (${res.status})`);
  }
  return payload;
}

async function api(path, options = {}) {
  const payload = await request(path, options);
  return payload?.data ?? null;
}

async function apiList(path) {
  const payload = await request(path);
  if (!Array.isArray(payload?.data)) {
    throw new Error('Некорректный ответ сервера');
  }
  return { data: payload.data, meta: payload.meta ?? null };
}

// ---------- Toast ----------

let toastTimer = null;
function showToast(message, isError = false) {
  const toast = $('toast');
  toast.textContent = message;
  toast.classList.toggle('is-error', isError);
  toast.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.add('hidden'), 3500);
}

function reportError(err) {
  showToast(err instanceof Error ? err.message : 'Неизвестная ошибка', true);
}

// ---------- Projects ----------

// При перерисовке списка replaceChildren() сбрасывает фокус на <body>;
// запоминаем, какой элемент списка был в фокусе, и возвращаем его.
function captureListFocus(listEl) {
  const active = document.activeElement;
  if (!listEl.contains(active)) return null;
  const item = active.closest('[data-id]');
  if (!item) return null;
  return { id: item.dataset.id, control: active.dataset.control ?? '' };
}

function restoreListFocus(listEl, saved) {
  if (!saved) return;
  const item = listEl.querySelector(`[data-id="${CSS.escape(saved.id)}"]`);
  if (!item) return;
  const target = saved.control ? item.querySelector(`[data-control="${saved.control}"]`) : item;
  (target ?? item).focus();
}

async function loadProjects() {
  const seq = ++state.projectsRequestSeq;
  const { data, meta } = await apiList(`/api/projects?limit=${LIST_LIMIT}`);
  if (seq !== state.projectsRequestSeq) return;
  state.projects = data;
  state.projectsTotal = meta?.total ?? data.length;
  renderProjects();
}

function renderProjects() {
  const list = $('project-list');
  const savedFocus = captureListFocus(list);
  list.replaceChildren();

  for (const project of state.projects) {
    const li = document.createElement('li');
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'project-item';
    btn.dataset.id = project.id;
    if (project.id === state.currentProjectId) btn.classList.add('is-active');

    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = project.name;

    const count = document.createElement('span');
    count.className = 'count';
    count.textContent = String(project.task_count);

    btn.append(name, count);
    btn.addEventListener('click', () => { selectProject(project.id).catch(reportError); });
    li.append(btn);
    list.append(li);
  }

  if (state.projectsTotal > state.projects.length) {
    const li = document.createElement('li');
    li.className = 'muted list-note';
    li.textContent = `Показано ${state.projects.length} из ${state.projectsTotal}`;
    list.append(li);
  }

  restoreListFocus(list, savedFocus);
}

async function selectProject(id) {
  const project = state.projects.find((p) => p.id === id);
  if (!project) return;

  state.currentProjectId = id;
  state.statusFilter = '';
  renderProjects();
  renderStatusFilter();
  hideTaskForm();
  hideProjectForm();

  $('empty-state').classList.add('hidden');
  $('project-view').classList.remove('hidden');
  $('current-project-name').textContent = project.name;
  $('current-project-description').textContent = project.description;

  // Сразу очищаем список, чтобы при медленном/упавшем запросе
  // под заголовком нового проекта не остались чужие задачи.
  state.tasks = [];
  renderTasks();
  await loadTasks();
}

function showProjectForm(project = null) {
  $('project-form').classList.remove('hidden');
  $('project-form-title').textContent = project ? 'Изменить проект' : 'Новый проект';
  $('project-form-id').value = project ? String(project.id) : '';
  $('project-name').value = project ? project.name : '';
  $('project-description').value = project ? project.description : '';
  $('project-name').focus();
}

function hideProjectForm() {
  $('project-form').classList.add('hidden');
  $('project-form').reset();
  $('project-form-id').value = '';
}

// Пока запрос в полёте, кнопка «Сохранить» выключена — двойной клик
// или зажатый Enter не создадут дубликат.
function guardSubmit(form, handler) {
  let busy = false;
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (busy) return;
    busy = true;
    const submitBtn = form.querySelector('button[type="submit"]');
    submitBtn.disabled = true;
    try {
      await handler();
    } finally {
      busy = false;
      submitBtn.disabled = false;
    }
  });
}

async function submitProjectForm() {
  const id = $('project-form-id').value;
  const body = JSON.stringify({
    name: $('project-name').value.trim(),
    description: $('project-description').value.trim(),
  });

  try {
    if (id) {
      await api(`/api/projects/${id}`, { method: 'PUT', body });
      showToast('Проект обновлён');
    } else {
      const created = await api('/api/projects', { method: 'POST', body });
      if (!created?.id) throw new Error('Некорректный ответ сервера');
      showToast('Проект создан');
      await loadProjects();
      hideProjectForm();
      await selectProject(created.id);
      return;
    }
    hideProjectForm();
    await loadProjects();
    if (state.currentProjectId) {
      const current = state.projects.find((p) => p.id === state.currentProjectId);
      if (current) {
        $('current-project-name').textContent = current.name;
        $('current-project-description').textContent = current.description;
      }
    }
  } catch (err) {
    reportError(err);
  }
}

async function deleteCurrentProject() {
  const project = state.projects.find((p) => p.id === state.currentProjectId);
  if (!project) return;
  if (!window.confirm(`Удалить проект «${project.name}» и все его задачи?`)) return;

  try {
    await api(`/api/projects/${project.id}`, { method: 'DELETE' });
    showToast('Проект удалён');
    state.currentProjectId = null;
    state.statusFilter = '';
    state.tasks = [];
    state.tasksRequestSeq += 1; // сбрасываем возможный запрос задач удалённого проекта
    hideProjectForm();
    hideTaskForm();
    $('project-view').classList.add('hidden');
    $('empty-state').classList.remove('hidden');
    await loadProjects();
  } catch (err) {
    reportError(err);
  }
}

// ---------- Tasks ----------

async function loadTasks() {
  if (!state.currentProjectId) return;
  // Монотонный номер запроса: при быстром переключении проектов/фильтров
  // поздно пришедший старый ответ не должен перетирать свежий.
  const seq = ++state.tasksRequestSeq;
  state.tasksLoading = true;
  state.tasksError = false;
  renderTasks();
  const params = new URLSearchParams({
    project_id: String(state.currentProjectId),
    limit: String(LIST_LIMIT),
  });
  if (state.statusFilter) params.set('status', state.statusFilter);
  try {
    const { data, meta } = await apiList(`/api/tasks?${params}`);
    if (seq !== state.tasksRequestSeq) return;
    state.tasks = data;
    state.tasksTotal = meta?.total ?? data.length;
    state.tasksLoading = false;
  } catch (err) {
    if (seq !== state.tasksRequestSeq) return;
    // Данные неизвестны — не оставляем на экране список от старого фильтра.
    state.tasks = [];
    state.tasksTotal = 0;
    state.tasksLoading = false;
    state.tasksError = true;
    renderTasks();
    throw err;
  }
  renderTasks();
}

function renderTasks() {
  const list = $('task-list');
  const savedFocus = captureListFocus(list);
  list.replaceChildren();

  // Подпись под списком: «пусто» показываем только когда точно знаем,
  // что задач нет; во время загрузки и после ошибки — свои сообщения.
  const note = $('task-list-empty');
  const truncated = state.tasksTotal > state.tasks.length;
  note.classList.toggle('is-error', state.tasksError);
  if (state.tasksError) {
    note.textContent = 'Не удалось загрузить задачи. Обновите страницу или попробуйте позже.';
    note.classList.remove('hidden');
  } else if (state.tasksLoading) {
    // Во время фоновой перезагрузки не мигаем: держим прежнюю подпись
    // об усечении, «Загрузка…» показываем только на пустом списке.
    if (state.tasks.length === 0) {
      note.textContent = 'Загрузка…';
      note.classList.remove('hidden');
    } else if (truncated) {
      note.textContent = `Показано ${state.tasks.length} из ${state.tasksTotal} задач.`;
      note.classList.remove('hidden');
    } else {
      note.classList.add('hidden');
    }
  } else if (state.tasks.length === 0) {
    note.textContent = 'Задач пока нет.';
    note.classList.remove('hidden');
  } else if (truncated) {
    note.textContent = `Показано ${state.tasks.length} из ${state.tasksTotal} задач.`;
    note.classList.remove('hidden');
  } else {
    note.classList.add('hidden');
  }

  for (const task of state.tasks) {
    list.append(buildTaskCard(task));
  }

  restoreListFocus(list, savedFocus);
}

function buildTaskCard(task) {
  const li = document.createElement('li');
  li.className = 'task-card';
  li.dataset.status = task.status;
  li.dataset.id = task.id;

  const stripe = document.createElement('span');
  stripe.className = 'stripe';
  stripe.setAttribute('aria-hidden', 'true');

  const body = document.createElement('div');
  const title = document.createElement('h3');
  title.textContent = task.title;
  body.append(title);
  if (task.description) {
    const desc = document.createElement('p');
    desc.textContent = task.description;
    body.append(desc);
  }

  const meta = document.createElement('div');
  meta.className = 'task-meta';

  const select = document.createElement('select');
  select.className = 'status-select';
  select.dataset.control = 'status';
  select.setAttribute('aria-label', `Статус задачи «${task.title}»`);
  for (const [value, label] of Object.entries(STATUS_LABELS)) {
    const option = document.createElement('option');
    option.value = value;
    option.textContent = label;
    option.selected = value === task.status;
    select.append(option);
  }
  select.addEventListener('change', async () => {
    try {
      await api(`/api/tasks/${task.id}`, {
        method: 'PUT',
        body: JSON.stringify({ status: select.value }),
      });
      await Promise.all([loadTasks(), loadProjects()]);
    } catch (err) {
      reportError(err);
      select.value = task.status;
    }
  });

  const actions = document.createElement('div');
  actions.className = 'task-actions';

  const editBtn = document.createElement('button');
  editBtn.type = 'button';
  editBtn.className = 'btn btn-ghost';
  editBtn.dataset.control = 'edit';
  editBtn.textContent = 'Изменить';
  editBtn.addEventListener('click', () => showTaskForm(task));

  const deleteBtn = document.createElement('button');
  deleteBtn.type = 'button';
  deleteBtn.className = 'btn btn-ghost';
  deleteBtn.dataset.control = 'delete';
  deleteBtn.textContent = 'Удалить';
  deleteBtn.addEventListener('click', async () => {
    if (!window.confirm(`Удалить задачу «${task.title}»?`)) return;
    try {
      await api(`/api/tasks/${task.id}`, { method: 'DELETE' });
      showToast('Задача удалена');
      await Promise.all([loadTasks(), loadProjects()]);
    } catch (err) {
      reportError(err);
    }
  });

  actions.append(editBtn, deleteBtn);
  meta.append(select, actions);
  li.append(stripe, body, meta);
  return li;
}

function showTaskForm(task = null) {
  $('task-form').classList.remove('hidden');
  $('task-form-title').textContent = task ? 'Изменить задачу' : 'Новая задача';
  $('task-form-id').value = task ? String(task.id) : '';
  $('task-title').value = task ? task.title : '';
  $('task-description').value = task ? task.description : '';
  $('task-status').value = task ? task.status : 'todo';
  $('task-title').focus();
}

function hideTaskForm() {
  $('task-form').classList.add('hidden');
  $('task-form').reset();
  $('task-form-id').value = '';
}

async function submitTaskForm() {
  const id = $('task-form-id').value;
  const payload = {
    title: $('task-title').value.trim(),
    description: $('task-description').value.trim(),
    status: $('task-status').value,
  };

  try {
    if (id) {
      await api(`/api/tasks/${id}`, { method: 'PUT', body: JSON.stringify(payload) });
      showToast('Задача обновлена');
    } else {
      payload.project_id = state.currentProjectId;
      await api('/api/tasks', { method: 'POST', body: JSON.stringify(payload) });
      showToast('Задача создана');
    }
    hideTaskForm();
    await Promise.all([loadTasks(), loadProjects()]);
  } catch (err) {
    reportError(err);
  }
}

function renderStatusFilter() {
  for (const chip of $('status-filter').querySelectorAll('.chip')) {
    const isActive = chip.dataset.status === state.statusFilter;
    chip.classList.toggle('is-active', isActive);
    chip.setAttribute('aria-pressed', String(isActive));
  }
}

// ---------- Init ----------

function bindEvents() {
  $('new-project-btn').addEventListener('click', () => showProjectForm());
  guardSubmit($('project-form'), submitProjectForm);
  $('project-form-cancel').addEventListener('click', hideProjectForm);

  $('edit-project-btn').addEventListener('click', () => {
    const project = state.projects.find((p) => p.id === state.currentProjectId);
    if (project) showProjectForm(project);
  });
  $('delete-project-btn').addEventListener('click', deleteCurrentProject);

  $('new-task-btn').addEventListener('click', () => showTaskForm());
  guardSubmit($('task-form'), submitTaskForm);
  $('task-form-cancel').addEventListener('click', hideTaskForm);

  $('status-filter').addEventListener('click', async (event) => {
    const chip = event.target.closest('.chip');
    if (!chip) return;
    state.statusFilter = chip.dataset.status;
    renderStatusFilter();
    try {
      await loadTasks();
    } catch (err) {
      reportError(err);
    }
  });
}

bindEvents();
loadProjects().catch(reportError);
