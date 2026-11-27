import type { ReactNode } from "react";

export function ErrorMessage({
  children,
  id,
}: {
  children: ReactNode;
  id?: string;
}) {
  if (!children) return null;
  return (
    <div className="error" role="alert" id={id}>
      {children}
    </div>
  );
}

export function StatusMessage({ children }: { children: ReactNode }) {
  if (!children) return null;
  return (
    <div className="status" aria-live="polite">
      {children}
    </div>
  );
}

export function Page({
  title,
  description,
  children,
}: {
  title: string;
  description?: string;
  children: ReactNode;
}) {
  return (
    <main className="page">
      <section className="panel" aria-labelledby="page-title">
        <h1 id="page-title">{title}</h1>
        {description ? <p className="lead">{description}</p> : null}
        {children}
      </section>
    </main>
  );
}
