"use client";

type Props = {
  title: string;
  isOwner: boolean;
  headingClass: string;
  isEditing: boolean;
  draft: string;
  onDraftChange: (d: string) => void;
  onStartEdit: () => void;
  onSave: () => void;
  onCancel: () => void;
  saving: boolean;
};

export function TitleEditor({
  title,
  isOwner,
  headingClass,
  isEditing,
  draft,
  onDraftChange,
  onStartEdit,
  onSave,
  onCancel,
  saving,
}: Props) {
  if (isEditing) {
    return (
      <input
        className={`font-heading font-bold text-text-primary bg-transparent border-b-2 border-[color:var(--brand-purple)] outline-none min-w-0 w-full ${headingClass}`}
        value={draft}
        onChange={(e) => onDraftChange(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") onSave();
          if (e.key === "Escape") onCancel();
        }}
        autoFocus
        disabled={saving}
      />
    );
  }

  if (!isOwner) {
    return (
      <h1 className={`font-heading font-bold text-text-primary ${headingClass}`}>
        {title}
      </h1>
    );
  }

  return (
    <div
      className="group inline-flex items-center gap-2 -mx-2 px-2 py-1 rounded-md transition-colors duration-[150ms] hover:bg-[var(--bg-card)] cursor-pointer"
      onClick={onStartEdit}
      title="Click to edit title"
    >
      <h1 className={`font-heading font-bold text-text-primary ${headingClass}`}>
        {title}
      </h1>
      <svg
        width="16"
        height="16"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden
        className="opacity-0 group-hover:opacity-100 max-md:opacity-100 transition-opacity duration-[150ms] text-text-tertiary flex-shrink-0"
      >
        <path d="M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z" />
      </svg>
    </div>
  );
}
