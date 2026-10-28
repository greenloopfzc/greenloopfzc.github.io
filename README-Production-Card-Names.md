# Daily Production ready stock card names

Total Stock is now Total Ready Stock. Grade cards display Grade <name> Ready Stock; RMA displays Ready RMA Stock without the Grade prefix. The same display titles are used when opening the report and in date-report scope choices. The existing report title also flows to the PDF preview. Only display labels and the script cache tag change; calculations, stored choices, grade IDs, card permissions and layout are preserved.

This label update needs no new SQL or Edge Function. The publisher retains the preceding Receipt Return Count update and its tested transient-error retries; if that earlier database update is still pending, its existing installer is included.
