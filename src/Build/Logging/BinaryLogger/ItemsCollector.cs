using Microsoft.Build.Exceptions;
using Microsoft.Build.Framework;
using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace Microsoft.Build.Logging.BinaryLogger
{
    /// <summary>
    /// 
    /// </summary>
    internal class ItemsEntryComparer : IEqualityComparer<ItemsEntry>
    {
        /// <summary>
        /// The point of this method is to be fast.
        /// </summary>
        /// <param name="x"></param>
        /// <param name="y"></param>
        /// <returns></returns>
        public bool Equals(ItemsEntry x, ItemsEntry y)
        {
            return true;
        }

        public int GetHashCode(ItemsEntry obj)
        {
            int hashCode = 0;
            foreach (var entry in obj.Items)
            {
                string key = entry.Key as string;
                ITaskItem item = entry.Value as ITaskItem;

                hashCode = unchecked(
                    hashCode + key.GetHashCode() + item.ItemSpec.GetHashCode());

                foreach (string metadataName in item.MetadataNames)
                {
                    string valueOrError;
                    try
                    {
                        valueOrError = item.GetMetadata(metadataName);
                    }
                    catch (InvalidProjectFileException e)
                    {
                        valueOrError = e.Message;
                    }
                    // Temporarily try catch all to mitigate frequent NullReferenceExceptions in
                    // the logging code until CopyOnWritePropertyDictionary is replaced with
                    // ImmutableDictionary. Calling into Debug.Fail to crash the process in case
                    // the exception occures in Debug builds.
                    catch (Exception e)
                    {
                        valueOrError = e.Message;
                    }

                    hashCode = unchecked(hashCode + metadataName.GetHashCode() + valueOrError.GetHashCode());
                }
            }

            return hashCode;
        }
    }

    /// <summary>
    /// A single items entry. Contains an index which is used when writing the
    /// entries into the build event args, but which is not used when comparing
    /// items.
    /// </summary>
    internal class ItemsEntry
    {
        public ItemsEntry(int index, List<DictionaryEntry> items)
        {
            _index = index;
            _items = Items;
        }

        private readonly int _index = 0;
        private readonly List<DictionaryEntry> _items;

        public int Index { get => _index; }
        public List<DictionaryEntry> Items { get => _items; }
    }

    internal class ItemsCollector
    {
        HashSet<ItemsEntry> _entries = new HashSet<ItemsEntry>(new ItemsEntryComparer());
        int currentIndex = 0;

        public int AddItems(List<DictionaryEntry> items)
        {
            lock (_entries)
            {
                if (_entries.TryGetValue(new ItemsEntry(0, items), out ItemsEntry existingItems))
                {
                    return existingItems.Index;
                }
                else
                {
                    foreach (DictionaryEntry entry in items)
                    {

                    }

                    _entries.Add(new ItemsEntry(currentIndex++, items));
                    return currentIndex;
                }
            }
        }
    }
}
