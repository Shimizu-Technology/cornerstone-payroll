declare module '@rails/actioncable' {
  export type Cable = {
    subscriptions: {
      create: (channel: string | Record<string, unknown>, mixin: Record<string, unknown>) => Channel;
      remove: (subscription: Channel) => void;
    };
    disconnect: () => void;
  };

  export type Channel = Record<string, unknown>;

  export function createConsumer(url?: string): Cable;
}
