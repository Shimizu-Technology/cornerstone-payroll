namespace :payroll do
  namespace :legacy_empty do
    desc "Print a read-only classification manifest for committed native payroll items (COMPANY_ID required)"
    task preview: :environment do
      company_id = Integer(ENV.fetch("COMPANY_ID"))
      puts JSON.pretty_generate(PayrollItemLegacyDispositionService.preview(company_id: company_id))
    end

    desc "Apply reviewed verified-empty item manifest (COMPANY_ID, ACTOR_ID, MANIFEST required)"
    task apply: :environment do
      company_id = Integer(ENV.fetch("COMPANY_ID"))
      actor = User.find(Integer(ENV.fetch("ACTOR_ID")))
      entries = JSON.parse(File.read(ENV.fetch("MANIFEST")))
      result = PayrollItemLegacyDispositionService.apply!(company_id: company_id, actor: actor, entries: entries)
      puts JSON.pretty_generate(result.map { |row| { payroll_item_id: row.payroll_item_id, disposition_id: row.id } })
    end
  end
end
