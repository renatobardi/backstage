import { createApp } from '@backstage/frontend-defaults';
import {
  configApiRef,
  createFrontendModule,
  useApi,
} from '@backstage/frontend-plugin-api';
import { SignInPageBlueprint } from '@backstage/plugin-app-react';
import { ProxiedSignInPage, SignInPage } from '@backstage/core-components';
import type { SignInPageProps } from '@backstage/core-plugin-api';
import catalogPlugin from '@backstage/plugin-catalog/alpha';
import { navModule } from './modules/nav';
import { homeModule } from './modules/home';

// Produção: sessão vem do oauth2-proxy (ADR-0011). Fora dela, guest para dev local.
function OuteSignInPage(props: SignInPageProps) {
  const configApi = useApi(configApiRef);
  if (configApi.getOptionalString('auth.environment') === 'production') {
    return <ProxiedSignInPage {...props} provider="oauth2Proxy" />;
  }
  return <SignInPage {...props} auto providers={['guest']} />;
}

const signInPage = SignInPageBlueprint.make({
  params: {
    loader: async () => props => <OuteSignInPage {...props} />,
  },
});

export default createApp({
  features: [
    catalogPlugin,
    navModule,
    homeModule,
    createFrontendModule({ pluginId: 'app', extensions: [signInPage] }),
  ],
});
