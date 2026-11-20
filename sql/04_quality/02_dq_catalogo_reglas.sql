/* =============================================================================
   02_dq_catalogo_reglas.sql — Catálogo de reglas de calidad (el "manual de controles").

   Cada regla tiene un id estable (lo usan los tests y los informes), categoría, tabla,
   severidad y momento (PRE_CARGA: sobre staging, antes de cargar; POST_CARGA: totales
   de control staging vs. DW, después de cargar). La lógica de cada regla está en
   03_usp_dq_validar_staging.sql y 04_usp_dq_controles_post_carga.sql.
   Idempotente: inserta las reglas nuevas y actualiza las que cambiaron.
   ============================================================================= */
SET NOCOUNT ON;
USE [$(DB_NAME)];
GO

DECLARE @reglas TABLE (regla_id VARCHAR(40), descripcion NVARCHAR(300), categoria VARCHAR(30), tabla SYSNAME,
                       severidad VARCHAR(12), momento VARCHAR(12));
INSERT INTO @reglas VALUES
-- facturas
('INV_ID_NULO',               N'Factura sin id interno',                                         'completitud',            'invoices', 'ERROR', 'PRE_CARGA'),
('INV_MONTO_NULO',            N'Factura sin monto',                                              'completitud',            'invoices', 'ERROR', 'PRE_CARGA'),
('INV_VENC_NULO',             N'Factura sin fecha de vencimiento',                               'completitud',            'invoices', 'ERROR', 'PRE_CARGA'),
('INV_DUPLICADO_ID',          N'El mismo id de factura aparece más de una vez',                  'unicidad',               'invoices', 'ERROR', 'PRE_CARGA'),
('INV_DUPLICADO_NUMERO',      N'Misma factura del proveedor (contraparte + número) cargada con otro id', 'unicidad',     'invoices', 'ERROR', 'PRE_CARGA'),
('INV_MONTO_FORMATO',         N'Monto que no es un número válido (ej. formato regional 1.234,56)', 'formato',             'invoices', 'ERROR', 'PRE_CARGA'),
('INV_FECHA_INVALIDA',        N'Fecha de emisión o vencimiento inexistente o mal formada',       'formato',                'invoices', 'ERROR', 'PRE_CARGA'),
('INV_MONEDA_INVALIDA',       N'Código de moneda que no es ISO 4217 o no se opera',              'formato',                'invoices', 'ERROR', 'PRE_CARGA'),
('INV_MONTO_NO_POSITIVO',     N'Monto de factura cero o negativo',                               'rango',                  'invoices', 'ERROR', 'PRE_CARGA'),
('INV_VENC_ANTES_EMISION',    N'Vencimiento anterior a la emisión',                              'rango',                  'invoices', 'ERROR', 'PRE_CARGA'),
('INV_CONTRAPARTE_INEXISTENTE', N'Factura de una contraparte que no está en el maestro',         'integridad_referencial', 'invoices', 'ERROR', 'PRE_CARGA'),
-- pagos
('PAG_DUPLICADO',             N'El mismo pago aparece más de una vez',                           'unicidad',               'payments', 'ERROR', 'PRE_CARGA'),
('PAG_CONTRAPARTE_NULA',      N'Pago sin contraparte',                                           'completitud',            'payments', 'ERROR', 'PRE_CARGA'),
('PAG_FECHA_INVALIDA',        N'Fecha de pago vacía, inexistente o mal formada',                 'formato',                'payments', 'ERROR', 'PRE_CARGA'),
('PAG_MONEDA_INVALIDA',       N'Código de moneda que no es ISO 4217 o no se opera',              'formato',                'payments', 'ERROR', 'PRE_CARGA'),
('PAG_FECHA_FUTURA',          N'Fecha de pago posterior al corte de la extracción',              'rango',                  'payments', 'ERROR', 'PRE_CARGA'),
('PAG_MONTO_NO_POSITIVO',     N'Monto de pago cero, negativo o no numérico',                     'rango',                  'payments', 'ERROR', 'PRE_CARGA'),
('PAG_FACTURA_INEXISTENTE',   N'Pago que referencia una factura inexistente',                    'integridad_referencial', 'payments', 'ERROR', 'PRE_CARGA'),
('PAG_CONTRAPARTE_INEXISTENTE', N'Pago a una contraparte que no está en el maestro',             'integridad_referencial', 'payments', 'ERROR', 'PRE_CARGA'),
('PAG_CUENTA_INEXISTENTE',    N'Pago desde una cuenta bancaria que no existe',                   'integridad_referencial', 'payments', 'ERROR', 'PRE_CARGA'),
('PAG_MONEDA_INCONSISTENTE',  N'Moneda del pago distinta a la de su factura o su cuenta',        'consistencia',           'payments', 'ERROR', 'PRE_CARGA'),
('PAG_SIN_EXTRACTO',          N'Pago del ERP sin débito en el extracto bancario (fuera del período de tránsito)', 'consistencia', 'payments', 'ADVERTENCIA', 'PRE_CARGA'),
-- cobranzas
('COB_DUPLICADO',             N'La misma cobranza aparece más de una vez',                       'unicidad',               'collections', 'ERROR', 'PRE_CARGA'),
('COB_MONEDA_NULA',           N'Cobranza sin moneda',                                            'completitud',            'collections', 'ERROR', 'PRE_CARGA'),
('COB_FECHA_INVALIDA',        N'Fecha de cobranza vacía, inexistente o mal formada',             'formato',                'collections', 'ERROR', 'PRE_CARGA'),
('COB_MONEDA_INVALIDA',       N'Código de moneda que no es ISO 4217 o no se opera',              'formato',                'collections', 'ERROR', 'PRE_CARGA'),
('COB_MONTO_NO_POSITIVO',     N'Monto de cobranza cero, negativo o no numérico',                 'rango',                  'collections', 'ERROR', 'PRE_CARGA'),
('COB_FACTURA_INEXISTENTE',   N'Cobranza que referencia una factura inexistente',                'integridad_referencial', 'collections', 'ERROR', 'PRE_CARGA'),
('COB_CONTRAPARTE_INEXISTENTE', N'Cobranza de una contraparte que no está en el maestro',        'integridad_referencial', 'collections', 'ERROR', 'PRE_CARGA'),
('COB_MONEDA_INCONSISTENTE',  N'Moneda de la cobranza distinta a la de su factura o su cuenta',  'consistencia',           'collections', 'ERROR', 'PRE_CARGA'),
('COB_SIN_EXTRACTO',          N'Cobranza del ERP sin crédito en el extracto bancario (fuera del período de tránsito)', 'consistencia', 'collections', 'ADVERTENCIA', 'PRE_CARGA'),
-- extracto bancario
('EXT_DUPLICADO',             N'Línea de extracto repetida (ej. el banco la reenvía el mes siguiente)', 'unicidad',       'bank_statements', 'ERROR', 'PRE_CARGA'),
('EXT_MONTO_NULO',            N'Línea de extracto sin importe o con importe no numérico',        'completitud',            'bank_statements', 'ERROR', 'PRE_CARGA'),
('EXT_FECHA_INVALIDA',        N'Fecha de imputación o valor inexistente o mal formada',          'formato',                'bank_statements', 'ERROR', 'PRE_CARGA'),
('EXT_CUENTA_DESCONOCIDA',    N'Línea de una cuenta bancaria que no está en el maestro',         'integridad_referencial', 'bank_statements', 'ERROR', 'PRE_CARGA'),
('EXT_MONEDA_INCONSISTENTE',  N'Moneda de la línea distinta a la de su cuenta',                  'consistencia',           'bank_statements', 'ERROR', 'PRE_CARGA'),
('EXT_SIN_MATCH',             N'Transferencia del banco sin pago ni cobranza en el ERP',         'consistencia',           'bank_statements', 'ADVERTENCIA', 'PRE_CARGA'),
-- tipos de cambio
('TC_NULO',                   N'Cotización vacía o no numérica',                                 'completitud',            'fx_rates', 'ERROR', 'PRE_CARGA'),
('TC_FALTANTE',               N'Día hábil sin cotización publicada para una moneda',             'completitud',            'fx_rates', 'ADVERTENCIA', 'PRE_CARGA'),
('TC_FUERA_DE_RANGO',         N'Cotización que salta más de 50% contra el día anterior y el siguiente', 'rango',          'fx_rates', 'ERROR', 'PRE_CARGA'),
-- maestro de contrapartes (advertencias: el maestro no se pone en cuarentena)
('CP_TAX_ID_NULO',            N'Contraparte sin identificación fiscal',                          'completitud',            'counterparties', 'ADVERTENCIA', 'PRE_CARGA'),
('CP_EMAIL_INVALIDO',         N'Email de contraparte con formato inválido',                      'formato',                'counterparties', 'ADVERTENCIA', 'PRE_CARGA'),
('CP_TAX_ID_DUPLICADO',       N'Dos contrapartes con la misma identificación fiscal',            'unicidad',               'counterparties', 'ADVERTENCIA', 'PRE_CARGA'),
-- totales de control staging vs. DW (después de cargar)
('CTL_FILAS_FACTURAS',        N'Facturas válidas en staging = facturas en el DW',                'totales_control',        'fact_facturas', 'ADVERTENCIA', 'POST_CARGA'),
('CTL_FILAS_PAGOS',           N'Pagos válidos en staging = pagos en el DW',                      'totales_control',        'fact_pagos', 'ADVERTENCIA', 'POST_CARGA'),
('CTL_FILAS_COBRANZAS',       N'Cobranzas válidas en staging = cobranzas en el DW',              'totales_control',        'fact_cobranzas', 'ADVERTENCIA', 'POST_CARGA'),
('CTL_FILAS_MOVIMIENTOS',     N'Líneas de extracto válidas en staging = movimientos en el DW',   'totales_control',        'fact_movimientos_bancarios', 'ADVERTENCIA', 'POST_CARGA'),
('CTL_MONTO_PAGOS',           N'Suma de pagos válidos en staging = suma en el DW, por moneda',   'totales_control',        'fact_pagos', 'ADVERTENCIA', 'POST_CARGA'),
('CTL_MONTO_COBRANZAS',       N'Suma de cobranzas válidas en staging = suma en el DW, por moneda', 'totales_control',      'fact_cobranzas', 'ADVERTENCIA', 'POST_CARGA'),
('CTL_MONTO_MOVIMIENTOS',     N'Suma de movimientos válidos en staging = suma en el DW, por moneda', 'totales_control',    'fact_movimientos_bancarios', 'ADVERTENCIA', 'POST_CARGA'),
('CTL_SALDO_EXTRACTO',        N'Saldo inicial + movimientos cargados = saldo final informado por el banco (cuenta x mes)', 'totales_control', 'fact_saldo_bancario_mensual', 'ADVERTENCIA', 'POST_CARGA'),
('CTL_SALDO_CONTINUIDAD',     N'Saldo final de un mes = saldo inicial del mes siguiente',        'totales_control',        'fact_saldo_bancario_mensual', 'ADVERTENCIA', 'POST_CARGA');

UPDATE r SET descripcion = s.descripcion, categoria = s.categoria, tabla = s.tabla, severidad = s.severidad,
             momento = s.momento
FROM audit.dq_reglas r JOIN @reglas s ON s.regla_id = r.regla_id
WHERE EXISTS (SELECT s.descripcion, s.categoria, s.tabla, s.severidad, s.momento
              EXCEPT SELECT r.descripcion, r.categoria, r.tabla, r.severidad, r.momento);

INSERT INTO audit.dq_reglas (regla_id, descripcion, categoria, tabla, severidad, momento)
SELECT regla_id, descripcion, categoria, tabla, severidad, momento
FROM @reglas s
WHERE NOT EXISTS (SELECT 1 FROM audit.dq_reglas r WHERE r.regla_id = s.regla_id);
GO

SELECT momento, categoria, severidad, COUNT(*) AS reglas
FROM audit.dq_reglas GROUP BY momento, categoria, severidad ORDER BY momento, categoria, severidad;
GO
