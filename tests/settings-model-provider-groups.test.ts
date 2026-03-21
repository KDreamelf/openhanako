import { describe, expect, it } from 'vitest';
import { getVisibleModelProviderIds, groupSdkModelsByProvider } from '../desktop/src/react/settings/helpers';

describe('settings model provider visibility helpers', () => {
  it('只保留当前已配置或已登录的 provider 分组', () => {
    const visibleProviders = getVisibleModelProviderIds(
      { 'openai-codex': {}, minimax: {} },
      { 'openai-codex': { loggedIn: true }, openai: { loggedIn: false } },
    );

    const grouped = groupSdkModelsByProvider([
      { id: 'gpt-5.4', provider: 'openai-codex' },
      { id: 'gpt-4.1', provider: 'openai' },
      { id: 'MiniMax-M1', provider: 'minimax' },
    ], visibleProviders);

    expect([...visibleProviders].sort()).toEqual(['minimax', 'openai-codex']);
    expect(grouped).toEqual({
      'openai-codex': ['gpt-5.4'],
      minimax: ['MiniMax-M1'],
    });
  });
});
