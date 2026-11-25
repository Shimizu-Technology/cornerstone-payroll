/** One name per role, so Users, the sidebar and alert recipients agree. */
const ROLE_LABELS: Record<string, string> = {
  super_admin: 'Super Admin',
  org_admin: 'Organization Admin',
  // Older accounts keep the "admin" role; it has the same access.
  admin: 'Organization Admin',
  manager: 'Manager',
  accountant: 'Accountant',
  client: 'Client Portal User',
  employee: 'Employee',
};

export function roleLabel(role?: string | null): string {
  if (!role) return 'User';
  return ROLE_LABELS[role]
    ?? role.split('_').map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(' ');
}
