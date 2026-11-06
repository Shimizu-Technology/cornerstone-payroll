from pathlib import Path
import json,re,collections
P=Path(__file__).resolve().parent
before=json.loads((P/'actions-before.json').read_text());after=json.loads((P/'actions-after.json').read_text())
renames={'Overview':'Payroll','Process payroll':'Payroll','Open processing':'Payroll','Review checks and payments':'Checks & payments','Commit & Finalize':'Commit'}
def canonical(label):
 if re.match(r'^\d+ access records?$',label):return 'Access records (dynamic audit group count)'
 if label in renames:return renames[label]
 if label.startswith('Checks & direct deposit'):return 'Checks & payments'
 if label.startswith('Checks & payments'):return 'Checks & payments'
 if label.startswith('Open payroll item for '):return 'Open payroll item'
 if label=='View details':return 'Open payroll item'
 if re.match(r'^(Enter|Adjust) Hours',label):return label.split(' Hours')[0]+' Hours'
 return label
rows=[]
for state,width in sorted({(i['state'],i['width']) for i in before}):
 old=collections.defaultdict(list);new=collections.defaultdict(list)
 for block in before:
  if (block['state'],block['width'])==(state,width):
   for action in block['actions']:old[canonical(action['label'])].append({**action,'tab':block['tab']})
 for block in after:
  if (block['state'],block['width'])==(state,width):
   for action in block['actions']:new[canonical(action['label'])].append(action)
 for label,actions in old.items():
  locations=sorted({a['location']+(' → '+a['disclosure'] if a['disclosure'] else '') for a in new.get(label,[])})
  status='retained' if label in new else 'unexplained'
  if label in ['What happened','Access records (dynamic audit group count)'] and label not in new:
   status='retained in paginated activity';locations=[f'Activity → Load older activity → {label} (unchanged activity/audit components; first-page event window changed)']
  rows.append({'state':state,'width':width,'original_labels':sorted({a['label'] for a in actions}),'canonical_action':label,'before_locations':sorted({a['tab']+' → '+a['location'] for a in actions}),'after_locations':locations,'classification':status})
result={'baseline':'origin/staging-v2 34c99bb2 (includes #383 and #382)','runtime_before_pages':len(before),'runtime_after_state_viewports':len(after),'normalizations':renames,'normalization_rules':['Checks tab counters are dynamic','Employee-specific Open payroll item and View details share the existing review dialog','Hours disclosure labels include nested filter text; compare their Enter/Adjust Hours label','N access records is a dynamic audit-group count; older events remain paginated'],'actions':rows,'unexplained':[x for x in rows if x['classification']=='unexplained']}
(P/'actions-location-diff.json').write_text(json.dumps(result,indent=2))
print('Rows',len(rows),'unexplained',len(result['unexplained']))
for row in result['unexplained']:print(row['state'],row['width'],row['original_labels'])
