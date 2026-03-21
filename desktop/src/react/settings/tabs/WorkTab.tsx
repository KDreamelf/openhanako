import React, { useState, useEffect } from 'react';
import { useSettingsStore } from '../store';
import { t, autoSaveConfig, autoSaveGlobalPreferences } from '../helpers';
import { Toggle } from '../widgets/Toggle';
import { SelectWidget } from '../widgets/SelectWidget';

const platform = (window as any).platform;
const isWindows = document.documentElement.dataset.platform === 'win32';

const DEFAULT_PROXY = {
  mode: 'system',
  manual: {
    httpProxy: '',
    httpsProxy: '',
    noProxy: '',
  },
};

const DEFAULT_BASH = {
  mode: 'smart',
  git_dir: '',
};

export function WorkTab() {
  const { settingsConfig, globalModelsConfig, showToast } = useSettingsStore();
  const [homeFolder, setHomeFolder] = useState('');
  const [hbEnabled, setHbEnabled] = useState(true);
  const [hbInterval, setHbInterval] = useState(17);
  const [cronAutoApprove, setCronAutoApprove] = useState(true);
  const [proxyMode, setProxyMode] = useState('system');
  const [httpProxy, setHttpProxy] = useState('');
  const [httpsProxy, setHttpsProxy] = useState('');
  const [noProxy, setNoProxy] = useState('');
  const [bashMode, setBashMode] = useState('smart');
  const [gitDir, setGitDir] = useState('');

  useEffect(() => {
    if (settingsConfig) {
      setHomeFolder(settingsConfig.desk?.home_folder || '');
      setHbEnabled(settingsConfig.desk?.heartbeat_enabled !== false);
      setHbInterval(settingsConfig.desk?.heartbeat_interval ?? 17);
      setCronAutoApprove(settingsConfig.desk?.cron_auto_approve !== false);
    }
  }, [settingsConfig]);

  useEffect(() => {
    const proxy = globalModelsConfig?.proxy || DEFAULT_PROXY;
    setProxyMode(proxy.mode || 'system');
    setHttpProxy(proxy.manual?.httpProxy || '');
    setHttpsProxy(proxy.manual?.httpsProxy || '');
    setNoProxy(proxy.manual?.noProxy || '');
    const bash = globalModelsConfig?.bash || DEFAULT_BASH;
    setBashMode(bash.mode || 'smart');
    setGitDir(bash.git_dir || '');
  }, [globalModelsConfig]);

  const savedBash = globalModelsConfig?.bash || DEFAULT_BASH;
  const bashDirty = savedBash.mode !== bashMode || (savedBash.git_dir || '') !== gitDir;
  const bashDetection = !bashDirty ? globalModelsConfig?.bash_detection : null;

  const pickHomeFolder = async () => {
    const folder = await platform?.selectFolder?.();
    if (!folder) return;
    setHomeFolder(folder);
    useSettingsStore.setState({ homeFolder: folder });
    await autoSaveConfig({ desk: { home_folder: folder } });
  };

  const clearHomeFolder = async () => {
    setHomeFolder('');
    useSettingsStore.setState({ homeFolder: null });
    await autoSaveConfig({ desk: { home_folder: '' } });
  };

  const toggleHeartbeat = async (on: boolean) => {
    setHbEnabled(on);
    await autoSaveConfig({ desk: { heartbeat_enabled: on } });
  };

  const toggleCronAutoApprove = async (on: boolean) => {
    setCronAutoApprove(on);
    await autoSaveConfig({ desk: { cron_auto_approve: on } });
  };

  const pickGitDir = async () => {
    const folder = await platform?.selectFolder?.();
    if (!folder) return;
    setGitDir(folder);
  };

  const clearGitDir = () => {
    setGitDir('');
  };

  const saveProxy = async (mode = proxyMode, opts: { silent?: boolean } = {}) => {
    await autoSaveGlobalPreferences({
      proxy: {
        mode,
        manual: {
          httpProxy: httpProxy.trim(),
          httpsProxy: httpsProxy.trim(),
          noProxy: noProxy.trim(),
        },
      },
    }, opts);
  };

  const buildBashConfig = () => ({
    mode: bashMode,
    git_dir: gitDir.trim(),
  });

  const onProxyModeChange = async (mode: string) => {
    setProxyMode(mode);
    if (mode !== 'manual') {
      await saveProxy(mode);
    }
  };

  const saveWork = async () => {
    const interval = Math.max(1, Math.min(120, hbInterval));
    if (isWindows && bashMode === 'custom_git' && !gitDir.trim()) {
      showToast(t('settings.work.gitDirRequired'), 'error');
      return;
    }
    await autoSaveConfig({ desk: { heartbeat_interval: interval } }, { silent: true });
    await autoSaveGlobalPreferences({
      proxy: {
        mode: proxyMode,
        manual: {
          httpProxy: httpProxy.trim(),
          httpsProxy: httpsProxy.trim(),
          noProxy: noProxy.trim(),
        },
      },
      ...(isWindows ? { bash: buildBashConfig() } : {}),
    }, { silent: true });
    showToast(t('settings.autoSaved'), 'success');
  };

  return (
    <div className="settings-tab-content active" data-tab="work">
      {/* 主文件夹 */}
      <section className="settings-section">
        <h2 className="settings-section-title">{t('settings.work.homeFolder')}</h2>
        <p className="settings-desc settings-desc-compact">
          {t('settings.work.homeFolderDesc')}
        </p>
        <div className="settings-folder-picker">
          <input
            type="text"
            className="settings-input settings-folder-input"
            readOnly
            value={homeFolder}
            placeholder={t('settings.work.homeFolderPlaceholder')}
            onClick={pickHomeFolder}
          />
          <button className="settings-folder-browse" onClick={pickHomeFolder}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z" />
            </svg>
          </button>
          {homeFolder && (
            <button
              className="settings-folder-clear"
              onClick={clearHomeFolder}
              title={t('settings.work.homeFolderClear')}
            >
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <line x1="18" y1="6" x2="6" y2="18" />
                <line x1="6" y1="6" x2="18" y2="18" />
              </svg>
            </button>
          )}
        </div>
      </section>

      {/* 代理 */}
      <section className="settings-section">
        <h2 className="settings-section-title">{t('settings.proxy.title')}</h2>
        <p className="settings-desc settings-desc-compact">
          {t('settings.proxy.desc')}
        </p>
        <div className="settings-field">
          <label className="settings-field-label">{t('settings.proxy.mode')}</label>
          <SelectWidget
            options={[
              { value: 'none', label: t('settings.proxy.modes.none') },
              { value: 'system', label: t('settings.proxy.modes.system') },
              { value: 'manual', label: t('settings.proxy.modes.manual') },
            ]}
            value={proxyMode}
            onChange={onProxyModeChange}
            placeholder={t('settings.proxy.mode')}
          />
          <span className="settings-field-hint">{t('settings.proxy.modeHint')}</span>
        </div>
        {proxyMode === 'system' && (
          <p className="settings-hint">{t('settings.proxy.systemHint')}</p>
        )}
        {proxyMode === 'manual' && (
          <>
            <div className="settings-row">
              <div className="settings-field settings-field-half">
                <label className="settings-field-label">{t('settings.proxy.httpProxy')}</label>
                <input
                  type="text"
                  className="settings-input"
                  value={httpProxy}
                  onChange={(e) => setHttpProxy(e.target.value)}
                  placeholder="http://127.0.0.1:7897"
                />
              </div>
              <div className="settings-field settings-field-half">
                <label className="settings-field-label">{t('settings.proxy.httpsProxy')}</label>
                <input
                  type="text"
                  className="settings-input"
                  value={httpsProxy}
                  onChange={(e) => setHttpsProxy(e.target.value)}
                  placeholder="http://127.0.0.1:7897"
                />
              </div>
            </div>
            <div className="settings-field">
              <label className="settings-field-label">{t('settings.proxy.noProxy')}</label>
              <input
                type="text"
                className="settings-input"
                value={noProxy}
                onChange={(e) => setNoProxy(e.target.value)}
                placeholder="localhost,127.0.0.1,::1"
              />
              <span className="settings-field-hint">{t('settings.proxy.noProxyHint')}</span>
            </div>
          </>
        )}
      </section>

      {isWindows && (
        <section className="settings-section">
          <h2 className="settings-section-title">{t('settings.work.bashTitle')}</h2>
          <p className="settings-desc settings-desc-compact">
            {t('settings.work.bashDesc')}
          </p>
          <div className="settings-field">
            <label className="settings-field-label">{t('settings.work.bashMode')}</label>
            <SelectWidget
              options={[
                { value: 'smart', label: t('settings.work.bashModes.smart') },
                { value: 'custom_git', label: t('settings.work.bashModes.customGit') },
              ]}
              value={bashMode}
              onChange={setBashMode}
              placeholder={t('settings.work.bashMode')}
            />
            <span className="settings-field-hint">{t('settings.work.bashModeHint')}</span>
          </div>
          {bashMode === 'custom_git' && (
            <div className="settings-field">
              <label className="settings-field-label">{t('settings.work.gitDir')}</label>
              <div className="settings-folder-picker">
                <input
                  type="text"
                  className="settings-input settings-folder-input"
                  readOnly
                  value={gitDir}
                  placeholder={t('settings.work.gitDirPlaceholder')}
                  onClick={pickGitDir}
                />
                <button className="settings-folder-browse" onClick={pickGitDir}>
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z" />
                  </svg>
                </button>
                {gitDir && (
                  <button
                    className="settings-folder-clear"
                    onClick={clearGitDir}
                    title={t('settings.work.homeFolderClear')}
                  >
                    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                      <line x1="18" y1="6" x2="6" y2="18" />
                      <line x1="6" y1="6" x2="18" y2="18" />
                    </svg>
                  </button>
                )}
              </div>
              <span className="settings-field-hint">{t('settings.work.gitDirHint')}</span>
            </div>
          )}
          {bashDetection?.found && (
            <div className="settings-field">
              <span className="settings-field-hint">{t('settings.work.bashResolved', { path: bashDetection.bash_path || bashDetection.git_dir })}</span>
            </div>
          )}
          {bashDetection && !bashDetection.found && (
            <div className="settings-field">
              {bashMode === 'smart' && (
                <div className="settings-field-hint settings-field-hint-warn">{t('settings.work.bashSmartMissing')}</div>
              )}
              <div className="settings-field-hint settings-field-hint-warn" style={{ whiteSpace: 'pre-line' }}>
                {bashDetection.message}
              </div>
            </div>
          )}
        </section>
      )}

      {/* 巡检 */}
      <section className="settings-section">
        <h2 className="settings-section-title">{t('settings.work.title')}</h2>
        <div className="tool-caps-group">
          <div className="tool-caps-item">
            <div className="tool-caps-label">
              <span className="tool-caps-name">{t('settings.work.heartbeatEnabled')}</span>
              <span className="tool-caps-desc">{t('settings.work.heartbeatDesc')}</span>
            </div>
            <Toggle
              on={hbEnabled}
              onChange={toggleHeartbeat}
            />
          </div>
          <div className={`tool-caps-item${hbEnabled ? '' : ' settings-disabled'}`}>
            <div className="tool-caps-label">
              <span className="tool-caps-name">{t('settings.work.heartbeatInterval')}</span>
            </div>
            <div className="settings-input-group">
              <input
                type="number"
                className="settings-input small"
                min={1}
                max={120}
                value={hbInterval}
                disabled={!hbEnabled}
                onChange={(e) => setHbInterval(parseInt(e.target.value) || 15)}
              />
              <span className="settings-input-unit">{t('settings.work.heartbeatUnit')}</span>
            </div>
          </div>
          <div className="tool-caps-item">
            <div className="tool-caps-label">
              <span className="tool-caps-name">{t('settings.work.cronAutoApprove')}</span>
              <span className="tool-caps-desc">{t('settings.work.cronAutoApproveDesc')}</span>
            </div>
            <Toggle
              on={cronAutoApprove}
              onChange={toggleCronAutoApprove}
            />
          </div>
        </div>
      </section>

      <div className="settings-section-footer">
        <button className="settings-save-btn-sm" onClick={saveWork}>
          {t('settings.save')}
        </button>
      </div>
    </div>
  );
}
